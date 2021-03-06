/**
	Automatic REST interface and client code generation facilities.

	Copyright: © 2012-2016 RejectedSoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig, Михаил Страшун
*/
module vibe.web.rest;

public import vibe.web.common;

import vibe.core.log;
import vibe.http.router : URLRouter;
import vibe.http.client : HTTPClientSettings;
import vibe.http.common : HTTPMethod;
import vibe.http.server : HTTPServerRequestDelegate;
import vibe.http.status : isSuccessCode;
import vibe.internal.meta.uda;
import vibe.internal.meta.funcattr;
import vibe.inet.url;
import vibe.inet.message : InetHeaderMap;
import vibe.web.internal.rest.common : RestInterface, Route, SubInterfaceType;
import vibe.web.auth : AuthInfo, handleAuthentication, handleAuthorization, isAuthenticated;

import std.algorithm : startsWith, endsWith;
import std.range : isOutputRange;
import std.typecons : Nullable;
import std.typetuple : anySatisfy, Filter;
import std.traits;

/**
	Registers a REST interface and connects it the the given instance.

	Each method of the given class instance is mapped to the corresponing HTTP
	verb. Property methods are mapped to GET/PUT and all other methods are
	mapped according to their prefix verb. If the method has no known prefix,
	POST is used. The rest of the name is mapped to the path of the route
	according to the given `method_style`. Note that the prefix word must be
	all-lowercase and is delimited by either an upper case character, a
	non-alphabetic character, or the end of the string.

	The following table lists the mappings from prefix verb to HTTP verb:

	$(TABLE
		$(TR $(TH HTTP method) $(TH Recognized prefixes))
		$(TR $(TD GET)	  $(TD get, query))
		$(TR $(TD PUT)    $(TD set, put))
		$(TR $(TD POST)   $(TD add, create, post))
		$(TR $(TD DELETE) $(TD remove, erase, delete))
		$(TR $(TD PATCH)  $(TD update, patch))
	)

	If a method has its first parameter named 'id', it will be mapped to ':id/method' and
	'id' is expected to be part of the URL instead of a JSON request. Parameters with default
	values will be optional in the corresponding JSON request.

	Any interface that you return from a getter will be made available with the
	base url and its name appended.

	Params:
		router = The HTTP router on which the interface will be registered
		instance = Class instance to use for the REST mapping - Note that TImpl
			must either be an interface type, or a class which derives from a
			single interface
		settings = Additional settings, such as the $(D MethodStyle), or the prefix.
			See $(D RestInterfaceSettings) for more details.

	See_Also:
		$(D RestInterfaceClient) class for a seamless way to access such a generated API

*/
URLRouter registerRestInterface(TImpl)(URLRouter router, TImpl instance, RestInterfaceSettings settings = null)
{
	import std.algorithm : filter, map, all;
	import std.array : array;
	import std.range : front;
	import vibe.web.internal.rest.common : ParameterKind;

	auto intf = RestInterface!TImpl(settings, false);

	foreach (i, ovrld; intf.SubInterfaceFunctions) {
		enum fname = __traits(identifier, intf.SubInterfaceFunctions[i]);
		alias R = ReturnType!ovrld;

		static if (isInstanceOf!(Collection, R)) {
			auto ret = __traits(getMember, instance, fname)(R.ParentIDs.init);
			router.registerRestInterface!(R.Interface)(ret.m_interface, intf.subInterfaces[i].settings);
		} else {
			auto ret = __traits(getMember, instance, fname)();
			router.registerRestInterface!R(ret, intf.subInterfaces[i].settings);
		}
	}


	foreach (i, func; intf.RouteFunctions) {
		auto route = intf.routes[i];

		// normal handler
		auto handler = jsonMethodHandler!(func, i)(instance, intf);

		auto diagparams = route.parameters.filter!(p => p.kind != ParameterKind.internal).map!(p => p.fieldName).array;
		logDiagnostic("REST route: %s %s %s", route.method, route.fullPattern, diagparams);
		router.match(route.method, route.fullPattern, handler);
	}

	// here we filter our already existing OPTIONS routes, so we don't overwrite whenever the user explicitly made his own OPTIONS route
	auto routesGroupedByPattern = intf.getRoutesGroupedByPattern.filter!(rs => rs.all!(r => r.method != HTTPMethod.OPTIONS));

	foreach(routes; routesGroupedByPattern){
		auto route = routes.front;
		auto handler = optionsMethodHandler(routes, settings);

		auto diagparams = route.parameters.filter!(p => p.kind != ParameterKind.internal).map!(p => p.fieldName).array;
		logDiagnostic("REST route: %s %s %s", HTTPMethod.OPTIONS, route.fullPattern, diagparams);
		router.match(HTTPMethod.OPTIONS, route.fullPattern, handler);
	}
	return router;
}

/// ditto
URLRouter registerRestInterface(TImpl)(URLRouter router, TImpl instance, MethodStyle style)
{
	return registerRestInterface(router, instance, "/", style);
}

/// ditto
URLRouter registerRestInterface(TImpl)(URLRouter router, TImpl instance, string url_prefix,
	MethodStyle style = MethodStyle.lowerUnderscored)
{
	auto settings = new RestInterfaceSettings;
	if (!url_prefix.startsWith("/")) url_prefix = "/"~url_prefix;
	settings.baseURL = URL("http://127.0.0.1"~url_prefix);
	settings.methodStyle = style;
	return registerRestInterface(router, instance, settings);
}


/**
	This is a very limited example of REST interface features. Please refer to
	the "rest" project in the "examples" folder for a full overview.

	All details related to HTTP are inferred from the interface declaration.
*/
unittest
{
	@path("/")
	interface IMyAPI
	{
		// GET /api/greeting
		@property string greeting();

		// PUT /api/greeting
		@property void greeting(string text);

		// POST /api/users
		@path("/users")
		void addNewUser(string name);

		// GET /api/users
		@property string[] users();

		// GET /api/:id/name
		string getName(int id);

		// GET /some_custom_json
		Json getSomeCustomJson();
	}

	// vibe.d takes care of all JSON encoding/decoding
	// and actual API implementation can work directly
	// with native types

	class API : IMyAPI
	{
		private {
			string m_greeting;
			string[] m_users;
		}

		@property string greeting() { return m_greeting; }
		@property void greeting(string text) { m_greeting = text; }

		void addNewUser(string name) { m_users ~= name; }

		@property string[] users() { return m_users; }

		string getName(int id) { return m_users[id]; }

		Json getSomeCustomJson()
		{
			Json ret = Json.emptyObject;
			ret["somefield"] = "Hello, World!";
			return ret;
		}
	}

	// actual usage, this is usually done in app.d module
	// constructor

	void static_this()
	{
		import vibe.http.server, vibe.http.router;

		auto router = new URLRouter;
		router.registerRestInterface(new API());
		listenHTTP(new HTTPServerSettings(), router);
	}
}


/**
	Returns a HTTP handler delegate that serves a JavaScript REST client.
*/
HTTPServerRequestDelegate serveRestJSClient(I)(RestInterfaceSettings settings)
	if (is(I == interface))
{
	import std.digest.md : md5Of;
	import std.digest.digest : toHexString;
	import std.array : appender;
	import vibe.http.server : HTTPServerRequest, HTTPServerResponse;
	import vibe.http.status : HTTPStatus;

	auto app = appender!string();
	generateRestJSClient!I(app, settings);
	auto hash = app.data.md5Of.toHexString.idup;

	void serve(HTTPServerRequest req, HTTPServerResponse res)
	{
		if (auto pv = "If-None-Match" in res.headers) {
			res.statusCode = HTTPStatus.notModified;
			res.writeVoidBody();
			return;
		}

		res.headers["Etag"] = hash;
		res.writeBody(app.data, "application/javascript; charset=UTF-8");
	}

	return &serve;
}
/// ditto
HTTPServerRequestDelegate serveRestJSClient(I)(URL base_url)
{
	auto settings = new RestInterfaceSettings;
	settings.baseURL = base_url;
	return serveRestJSClient(settings);
}
/// ditto
HTTPServerRequestDelegate serveRestJSClient(I)(string base_url)
{
	auto settings = new RestInterfaceSettings;
	settings.baseURL = URL(base_url);
	return serveRestJSClient(settings);
}

///
unittest {
	import vibe.http.server;

	interface MyAPI {
		string getFoo();
		void postBar(string param);
	}

	void test()
	{
		auto restsettings = new RestInterfaceSettings;
		restsettings.baseURL = URL("http://api.example.org/");

		auto router = new URLRouter;
		router.get("/myapi.js", serveRestJSClient!MyAPI(restsettings));
		//router.get("/", staticTemplate!"index.dt");

		listenHTTP(new HTTPServerSettings, router);
	}

	/*
		index.dt:
		html
			head
				title JS REST client test
				script(src="test.js")
			body
				button(onclick="MyAPI.postBar('hello');")
	*/
}


/**
	Generates JavaScript code to access a REST interface from the browser.
*/
void generateRestJSClient(I, R)(ref R output, RestInterfaceSettings settings = null)
	if (is(I == interface) && isOutputRange!(R, char))
{
	import vibe.web.internal.rest.jsclient : generateInterface;
	output.generateInterface!I(null, settings);
}

/// Writes a JavaScript REST client to a local .js file.
unittest {
	import vibe.core.file;

	interface MyAPI {
		void getFoo();
		void postBar(string param);
	}

	void generateJSClientImpl()
	{
		import std.array : appender;

		auto app = appender!string;
		generateRestJSClient!MyAPI(app);
		writeFileUTF8(Path("myapi.js"), app.data);
	}
}


/**
	Implements the given interface by forwarding all public methods to a REST server.

	The server must talk the same protocol as registerRestInterface() generates. Be sure to set
	the matching method style for this. The RestInterfaceClient class will derive from the
	interface that is passed as a template argument. It can be used as a drop-in replacement
	of the real implementation of the API this way.
*/
class RestInterfaceClient(I) : I
{
	import vibe.inet.url : URL, PathEntry;
	import vibe.http.client : HTTPClientRequest;
	import std.typetuple : staticMap;

	private alias Info = RestInterface!I;

	//pragma(msg, "imports for "~I.stringof~":");
	//pragma(msg, generateModuleImports!(I)());
	mixin(generateModuleImports!I());

	private {
		// storing this struct directly causes a segfault when built with
		// LDC 0.15.x, so we are using a pointer here:
		RestInterface!I* m_intf;
		RequestFilter m_requestFilter;
		staticMap!(RestInterfaceClient, Info.SubInterfaceTypes) m_subInterfaces;
	}

	alias RequestFilter = void delegate(HTTPClientRequest req);

	/**
		Creates a new REST client implementation of $(D I).
	*/
	this(RestInterfaceSettings settings)
	{
		m_intf = new Info(settings, true);

		foreach (i, SI; Info.SubInterfaceTypes)
			m_subInterfaces[i] = new RestInterfaceClient!SI(m_intf.subInterfaces[i].settings);
	}

	/// ditto
	this(string base_url, MethodStyle style = MethodStyle.lowerUnderscored)
	{
		this(URL(base_url), style);
	}

	/// ditto
	this(URL base_url, MethodStyle style = MethodStyle.lowerUnderscored)
	{
		scope settings = new RestInterfaceSettings;
		settings.baseURL = base_url;
		settings.methodStyle = style;
		this(settings);
	}

	/**
		An optional request filter that allows to modify each request before it is made.
	*/
	final @property RequestFilter requestFilter()
	{
		return m_requestFilter;
	}

	/// ditto
	final @property void requestFilter(RequestFilter v)
	{
		m_requestFilter = v;
		foreach (i, SI; Info.SubInterfaceTypes)
			m_subInterfaces[i].requestFilter = v;
	}

	//pragma(msg, "restinterface:");
	mixin(generateRestClientMethods!I());

	protected {
		import vibe.data.json : Json;
		import vibe.textfilter.urlencode;

		/**
		 * Perform a request to the interface using the given parameters.
		 *
		 * Params:
		 * verb = Kind of request (See $(D HTTPMethod) enum).
		 * name = Location to request. For a request on https://github.com/rejectedsoftware/vibe.d/issues?q=author%3ASantaClaus,
		 *		it will be '/rejectedsoftware/vibe.d/issues'.
		 * hdrs = The headers to send. Some field might be overriden (such as Content-Length). However, Content-Type will NOT be overriden.
		 * query = The $(B encoded) query string. For a request on https://github.com/rejectedsoftware/vibe.d/issues?q=author%3ASantaClaus,
		 *		it will be 'author%3ASantaClaus'.
		 * body_ = The body to send, as a string. If a Content-Type is present in $(D hdrs), it will be used, otherwise it will default to
		 *		the generic type "application/json".
		 * reqReturnHdrs = A map of required return headers.
		 *				   To avoid returning unused headers, nothing is written
		 *				   to this structure unless there's an (usually empty)
		 *				   entry (= the key exists) with the same key.
		 *				   If any key present in `reqReturnHdrs` is not present
		 *				   in the response, an Exception is thrown.
		 * optReturnHdrs = A map of optional return headers.
		 *				   This behaves almost as exactly as reqReturnHdrs,
		 *				   except that non-existent key in the response will
		 *				   not cause it to throw, but rather to set this entry
		 *				   to 'null'.
		 *
		 * Returns:
		 *     The Json object returned by the request
		 */
		Json request(HTTPMethod verb, string name,
					 in ref InetHeaderMap hdrs, string query, string body_,
					 ref InetHeaderMap reqReturnHdrs,
					 ref InetHeaderMap optReturnHdrs) const
		{
			auto path = URL(m_intf.baseURL).pathString;

			if (name.length)
			{
				if (path.length && path[$ - 1] == '/' && name[0] == '/')
					path ~= name[1 .. $];
				else if (path.length && path[$ - 1] == '/' || name[0] == '/')
					path ~= name;
				else
					path ~= '/' ~ name;
			}

			auto httpsettings = m_intf.settings.httpClientSettings;

			return .request(URL(m_intf.baseURL), m_requestFilter, verb, path,
				hdrs, query, body_, reqReturnHdrs, optReturnHdrs, httpsettings);
		}
	}
}

///
unittest
{
	interface IMyApi
	{
		// GET /status
		string getStatus();

		// GET /greeting
		@property string greeting();
		// PUT /greeting
		@property void greeting(string text);

		// POST /new_user
		void addNewUser(string name);
		// GET /users
		@property string[] users();
		// GET /:id/name
		string getName(int id);

		Json getSomeCustomJson();
	}

	void test()
	{
		auto api = new RestInterfaceClient!IMyApi("http://127.0.0.1/api/");

		logInfo("Status: %s", api.getStatus());
		api.greeting = "Hello, World!";
		logInfo("Greeting message: %s", api.greeting);
		api.addNewUser("Peter");
		api.addNewUser("Igor");
		logInfo("Users: %s", api.users);
		logInfo("First user name: %s", api.getName(0));
	}
}


/**
	Encapsulates settings used to customize the generated REST interface.
*/
class RestInterfaceSettings {
	/** The public URL below which the REST interface is registered.
	*/
	URL baseURL;

	/** List of allowed origins for CORS

		Empty list is interpreted as allowing all origins (e.g. *)
	*/
	string[] allowedOrigins;

	/** Naming convention used for the generated URLs.
	*/
	MethodStyle methodStyle = MethodStyle.lowerUnderscored;

	/** Ignores a trailing underscore in method and function names.

		With this setting set to $(D true), it's possible to use names in the
		REST interface that are reserved words in D.
	*/
	bool stripTrailingUnderscore = true;

	/// Overrides the default HTTP client settings used by the `RestInterfaceClient`.
	HTTPClientSettings httpClientSettings;

	@property RestInterfaceSettings dup()
	const {
		auto ret = new RestInterfaceSettings;
		ret.baseURL = this.baseURL;
		ret.methodStyle = this.methodStyle;
		ret.stripTrailingUnderscore = this.stripTrailingUnderscore;
		ret.allowedOrigins = this.allowedOrigins.dup;
		return ret;
	}
}


/**
	Models REST collection interfaces using natural D syntax.

	Use this type as the return value of a REST interface getter method/property
	to model a collection of objects. `opIndex` is used to make the individual
	entries accessible using the `[index]` syntax. Nested collections are
	supported.

	The interface `I` needs to define a struct named `CollectionIndices`. The
	members of this struct denote the types and names of the indexes that lead
	to a particular resource. If a collection is nested within another
	collection, the order of these members must match the nesting order
	(outermost first).

	The parameter list of all of `I`'s methods must begin with all but the last
	entry in `CollectionIndices`. Methods that also match the last entry will be
	considered methods of a collection item (`collection[index].method()`),
	wheres all other methods will be considered methods of the collection
	itself (`collection.method()`).

	The name of the index parameters affects the default path of a method's
	route. Normal parameter names will be subject to the same rules as usual
	routes (see `registerRestInterface`) and will be mapped to query or form
	parameters at the protocol level. Names starting with an underscore will
	instead be mapped to path placeholders. For example,
	`void getName(int __item_id)` will be mapped to a GET request to the
	path `":item_id/name"`.
*/
struct Collection(I)
	if (is(I == interface))
{
	import std.typetuple;

	static assert(is(I.CollectionIndices == struct), "Collection interfaces must define a CollectionIndices struct.");

	alias Interface = I;
	alias AllIDs = TypeTuple!(typeof(I.CollectionIndices.tupleof));
	static if (__VERSION__ >= 2067)
		alias AllIDNames = FieldNameTuple!(I.CollectionIndices);
	else
		alias AllIDNames = TypeTuple!(__traits(allMembers, I.CollectionIndices));
	static assert(AllIDs.length >= 1, I.stringof~".CollectionIndices must define at least one member.");
	static assert(AllIDNames.length == AllIDs.length);
	alias ItemID = AllIDs[$-1];
	alias ParentIDs = AllIDs[0 .. $-1];
	alias ParentIDNames = AllIDNames[0 .. $-1];

	private {
		I m_interface;
		ParentIDs m_parentIDs;
	}

	/** Constructs a new collection instance that is tied to a particular
		parent collection entry.

		Params:
			api = The target interface imstance to be mapped as a collection
			pids = The indexes of all collections in which this collection is
				nested (if any)
	*/
	this(I api, ParentIDs pids)
	{
		m_interface = api;
		m_parentIDs = pids;
	}

	static struct Item {
		private {
			I m_interface;
			AllIDs m_id;
		}

		this(I api, AllIDs id)
		{
			m_interface = api;
			m_id = id;
		}

		// forward all item methods
		mixin(() {
			string ret;
			foreach (m; __traits(allMembers, I)) {
				foreach (ovrld; MemberFunctionsTuple!(I, m)) {
					alias PT = ParameterTypeTuple!ovrld;
					static if (matchesAllIDs!ovrld)
						ret ~= "auto "~m~"(ARGS...)(ARGS args) { return m_interface."~m~"(m_id, args); }\n";
				}
			}
			return ret;
		} ());
	}

	// Note: the example causes a recursive template instantiation if done as a documented unit test:
	/** Accesses a single collection entry.

		Example:
		---
		interface IMain {
			@property Collection!IItem items();
		}

		interface IItem {
			struct CollectionIndices {
				int _itemID;
			}

			@method(HTTPMethod.GET)
			string name(int _itemID);
		}

		void test(IMain main)
		{
			auto item_name = main.items[23].name; // equivalent to IItem.name(23)
		}
		---
	*/
	Item opIndex(ItemID id)
	{
		return Item(m_interface, m_parentIDs, id);
	}

	// forward all non-item methods
	mixin(() {
		string ret;
		foreach (m; __traits(allMembers, I)) {
			foreach (ovrld; MemberFunctionsTuple!(I, m)) {
				alias PT = ParameterTypeTuple!ovrld;
				static if (!matchesAllIDs!ovrld) {
					static assert(matchesParentIDs!ovrld,
						"Collection methods must take all parent IDs as the first parameters."~PT.stringof~"   "~ParentIDs.stringof);
					ret ~= "auto "~m~"(ARGS...)(ARGS args) { return m_interface."~m~"(m_parentIDs, args); }\n";
				}
			}
		}
		return ret;
	} ());

	private template matchesParentIDs(alias func) {
		static if (is(ParameterTypeTuple!func[0 .. ParentIDs.length] == ParentIDs)) {
			static if (ParentIDNames.length == 0) enum matchesParentIDs = true;
			else static if (ParameterIdentifierTuple!func[0 .. ParentIDNames.length] == ParentIDNames)
				enum matchesParentIDs = true;
			else enum matchesParentIDs = false;
		} else enum matchesParentIDs = false;
	}

	private template matchesAllIDs(alias func) {
		static if (is(ParameterTypeTuple!func[0 .. AllIDs.length] == AllIDs)) {
			static if (ParameterIdentifierTuple!func[0 .. AllIDNames.length] == AllIDNames)
				enum matchesAllIDs = true;
			else enum matchesAllIDs = false;
		} else enum matchesAllIDs = false;
	}
}

/// Model two nested collections using path based indexes
unittest {
	//
	// API definition
	//
	interface SubItemAPI {
		// Define the index path that leads to a sub item
		struct CollectionIndices {
			// The ID of the base item. This must match the definition in
			// ItemAPI.CollectionIndices
			string _item;
			// The index if the sub item
			int _index;
		}

		// GET /items/:item/subItems/length
		@property int length(string _item);

		// GET /items/:item/subItems/:index/squared_position
		int getSquaredPosition(string _item, int _index);
	}

	interface ItemAPI {
		// Define the index that identifies an item
		struct CollectionIndices {
			string _item;
		}

		// base path /items/:item/subItems
		Collection!SubItemAPI subItems(string _item);

		// GET /items/:item/name
		@property string name(string _item);
	}

	interface API {
		// a collection of items at the base path /items/
		Collection!ItemAPI items();
	}

	//
	// Local API implementation
	//
	class SubItemAPIImpl : SubItemAPI {
		@property int length(string _item) { return 10; }

		int getSquaredPosition(string _item, int _index) { return _index ^^ 2; }
	}

	class ItemAPIImpl : ItemAPI {
		private SubItemAPIImpl m_subItems;

		this() { m_subItems = new SubItemAPIImpl; }

		Collection!SubItemAPI subItems(string _item) { return Collection!SubItemAPI(m_subItems, _item); }

		string name(string _item) { return _item; }
	}

	class APIImpl : API {
		private ItemAPIImpl m_items;

		this() { m_items = new ItemAPIImpl; }

		Collection!ItemAPI items() { return Collection!ItemAPI(m_items); }
	}

	//
	// Resulting API usage
	//
	API api = new APIImpl; // A RestInterfaceClient!API would work just as well
	assert(api.items["foo"].name == "foo");
	assert(api.items["foo"].subItems.length == 10);
	assert(api.items["foo"].subItems[2].getSquaredPosition() == 4);
}

unittest {
	interface I {
		struct CollectionIndices {
			int id1;
			string id2;
		}

		void a(int id1, string id2);
		void b(int id1, int id2);
		void c(int id1, string p);
		void d(int id1, string id2, int p);
		void e(int id1, int id2, int p);
		void f(int id1, string p, int q);
	}

	Collection!I coll;
	static assert(is(typeof(coll["x"].a()) == void));
	static assert(is(typeof(coll.b(42)) == void));
	static assert(is(typeof(coll.c("foo")) == void));
	static assert(is(typeof(coll["x"].d(42)) == void));
	static assert(is(typeof(coll.e(42, 42)) == void));
	static assert(is(typeof(coll.f("foo", 42)) == void));
}

/// Model two nested collections using normal query parameters as indexes
unittest {
	//
	// API definition
	//
	interface SubItemAPI {
		// Define the index path that leads to a sub item
		struct CollectionIndices {
			// The ID of the base item. This must match the definition in
			// ItemAPI.CollectionIndices
			string item;
			// The index if the sub item
			int index;
		}

		// GET /items/subItems/length?item=...
		@property int length(string item);

		// GET /items/subItems/squared_position?item=...&index=...
		int getSquaredPosition(string item, int index);
	}

	interface ItemAPI {
		// Define the index that identifies an item
		struct CollectionIndices {
			string item;
		}

		// base path /items/subItems?item=...
		Collection!SubItemAPI subItems(string item);

		// GET /items/name?item=...
		@property string name(string item);
	}

	interface API {
		// a collection of items at the base path /items/
		Collection!ItemAPI items();
	}

	//
	// Local API implementation
	//
	class SubItemAPIImpl : SubItemAPI {
		@property int length(string item) { return 10; }

		int getSquaredPosition(string item, int index) { return index ^^ 2; }
	}

	class ItemAPIImpl : ItemAPI {
		private SubItemAPIImpl m_subItems;

		this() { m_subItems = new SubItemAPIImpl; }

		Collection!SubItemAPI subItems(string item) { return Collection!SubItemAPI(m_subItems, item); }

		string name(string item) { return item; }
	}

	class APIImpl : API {
		private ItemAPIImpl m_items;

		this() { m_items = new ItemAPIImpl; }

		Collection!ItemAPI items() { return Collection!ItemAPI(m_items); }
	}

	//
	// Resulting API usage
	//
	API api = new APIImpl; // A RestInterfaceClient!API would work just as well
	assert(api.items["foo"].name == "foo");
	assert(api.items["foo"].subItems.length == 10);
	assert(api.items["foo"].subItems[2].getSquaredPosition() == 4);
}

unittest {
	interface C {
		struct CollectionIndices {
			int _ax;
			int _b;
		}
		void testB(int _ax, int _b);
	}

	interface B {
		struct CollectionIndices {
			int _a;
		}
		Collection!C c();
		void testA(int _a);
	}

	interface A {
		Collection!B b();
	}

	static assert (!is(typeof(A.init.b[1].c[2].testB())));
}

/** Allows processing the server request/response before the handler method is called.

	Note that this attribute is only used by `registerRestInterface`, but not
	by the client generators. This attribute expects the name of a parameter that
	will receive its return value.

	Writing to the response body from within the specified hander function
	causes any further processing of the request to be skipped. In particular,
	the route handler method will not be called.

	Note:
		The example shows the drawback of this attribute. It generally is a
		leaky abstraction that propagates to the base interface. For this
		reason the use of this attribute is not recommended, unless there is
		no suitable alternative.
*/
alias before = vibe.internal.meta.funcattr.before;

///
unittest {
	import vibe.http.server : HTTPServerRequest, HTTPServerResponse;

	interface MyService {
		long getHeaderCount(size_t foo = 0);
	}

	size_t handler(HTTPServerRequest req, HTTPServerResponse res)
	{
		return req.headers.length;
	}

	class MyServiceImpl : MyService {
		// the "foo" parameter will receive the number of request headers
		@before!handler("foo")
		long getHeaderCount(size_t foo)
		{
			return foo;
		}
	}

	void test(URLRouter router)
	{
		router.registerRestInterface(new MyServiceImpl);
	}
}


/** Allows processing the return value of a handler method and the request/response objects.

	The value returned by the REST API will be the value returned by the last
	`@after` handler, which allows to post process the results of the handler
	method.

	Writing to the response body from within the specified handler function
	causes any further processing of the request ot be skipped, including
	any other `@after` annotations and writing the result value.
*/
alias after = vibe.internal.meta.funcattr.after;

///
unittest {
	import vibe.http.server : HTTPServerRequest, HTTPServerResponse;

	interface MyService {
		long getMagic();
	}

	long handler(long ret, HTTPServerRequest req, HTTPServerResponse res)
	{
		return ret * 2;
	}

	class MyServiceImpl : MyService{
		// the result reported by the REST API will be 42
		@after!handler
		long getMagic()
		{
			return 21;
		}
	}

	void test(URLRouter router)
	{
		router.registerRestInterface(new MyServiceImpl);
	}
}

/**
 * Generate an handler that will wrap the server's method
 *
 * This function returns an handler, generated at compile time, that
 * will deserialize the parameters, pass them to the function implemented
 * by the user, and return what it needs to return, be it header parameters
 * or body, which is at the moment either a pure string or a Json object.
 *
 * One thing that makes this method more complex that it needs be is the
 * inability for D to attach UDA to parameters. This means we have to roll
 * our own implementation, which tries to be as easy to use as possible.
 * We'll require the user to give the name of the parameter as a string to
 * our UDA. Hopefully, we're also able to detect at compile time if the user
 * made a typo of any kind (see $(D genInterfaceValidationError)).
 *
 * Note:
 * Lots of abbreviations are used to ease the code, such as
 * PTT (ParameterTypeTuple), WPAT (WebParamAttributeTuple)
 * and PWPAT (ParameterWebParamAttributeTuple).
 *
 * Params:
 *	T = type of the object which represent the REST server (user implemented).
 *	Func = An alias to the function of $(D T) to wrap.
 *
 *	inst = REST server on which to call our $(D Func).
 *	settings = REST server configuration.
 *
 * Returns:
 *	A delegate suitable to use as an handler for an HTTP request.
 */
private HTTPServerRequestDelegate jsonMethodHandler(alias Func, size_t ridx, T)(T inst, ref RestInterface!T intf)
{
	import std.string : format;
	import vibe.http.server : HTTPServerRequest, HTTPServerResponse;
	import vibe.http.common : HTTPStatusException, HTTPStatus, enforceBadRequest;
	import vibe.utils.string : sanitizeUTF8;
	import vibe.web.internal.rest.common : ParameterKind;
	import vibe.internal.meta.funcattr : IsAttributedParameter, computeAttributedParameterCtx;
	import vibe.textfilter.urlencode : urlDecode;

	enum Method = __traits(identifier, Func);
	alias PTypes = ParameterTypeTuple!Func;
	alias PDefaults = ParameterDefaultValueTuple!Func;
	alias RT = ReturnType!(FunctionTypeOf!Func);
	static const sroute = RestInterface!T.staticRoutes[ridx];
	auto route = intf.routes[ridx];
	auto settings = intf.settings;

	void handler(HTTPServerRequest req, HTTPServerResponse res)
	{
		if (route.bodyParameters.length) {
			logDebug("BODYPARAMS: %s %s", Method, route.bodyParameters.length);
			/*enforceBadRequest(req.contentType == "application/json",
				"The Content-Type header needs to be set to application/json.");*/
			enforceBadRequest(req.json.type != Json.Type.undefined,
				"The request body does not contain a valid JSON value.");
			enforceBadRequest(req.json.type == Json.Type.object,
				"The request body must contain a JSON object with an entry for each parameter.");
		}

		static if (isAuthenticated!(T, Func)) {
			auto auth_info = handleAuthentication!Func(inst, req, res);
			if (res.headerWritten) return;
		}

		PTypes params;

		foreach (i, PT; PTypes) {
			enum sparam = sroute.parameters[i];
			enum pname = sparam.name;
			auto fieldname = route.parameters[i].fieldName;
			static if (isInstanceOf!(Nullable, PT)) PT v;
			else Nullable!PT v;

			static if (sparam.kind == ParameterKind.auth) {
				v = auth_info;
			} else static if (sparam.kind == ParameterKind.query) {
				if (auto pv = fieldname in req.query)
					v = fromRestString!PT(*pv);
			} else static if (sparam.kind == ParameterKind.body_) {
				if (auto pv = fieldname in req.json) {
					try
						v = deserializeJson!PT(*pv);
					catch (JSONException e)
						enforceBadRequest(false, e.msg);
                }
			} else static if (sparam.kind == ParameterKind.header) {
				if (auto pv = fieldname in req.headers)
					v = fromRestString!PT(*pv);
			} else static if (sparam.kind == ParameterKind.attributed) {
				v = computeAttributedParameterCtx!(Func, pname)(inst, req, res);
			} else static if (sparam.kind == ParameterKind.internal) {
				if (auto pv = fieldname in req.params)
					v = fromRestString!PT(urlDecode(*pv));
			} else static assert(false, "Unhandled parameter kind.");

			static if (isInstanceOf!(Nullable, PT)) params[i] = v;
			else if (v.isNull()) {
				static if (!is(PDefaults[i] == void)) params[i] = PDefaults[i];
				else enforceBadRequest(false, "Missing non-optional "~sparam.kind.to!string~" parameter '"~(fieldname.length?fieldname:sparam.name)~"'.");
			} else params[i] = v;
		}

		static if (isAuthenticated!(T, Func))
			handleAuthorization!(T, Func, params)(auth_info);

		void handleCors()
		{
			import std.algorithm : any;
			import std.uni : sicmp;

			if (req.method == HTTPMethod.OPTIONS)
				return;
			auto origin = "Origin" in req.headers;
			if (origin is null)
				return;

			if (settings.allowedOrigins.length != 0 &&
				!settings.allowedOrigins.any!(org => org.sicmp((*origin)) == 0))
				return;

			res.headers["Access-Control-Allow-Origin"] = *origin;
			res.headers["Access-Control-Allow-Credentials"] = "true";
		}
		// Anti copy-paste
		void returnHeaders()
		{
			handleCors();
			foreach (i, P; PTypes) {
				static if (sroute.parameters[i].isOut) {
					static assert (sroute.parameters[i].kind == ParameterKind.header);
					static if (isInstanceOf!(Nullable, typeof(params[i]))) {
						if (!params[i].isNull)
							res.headers[route.parameters[i].fieldName] = to!string(params[i]);
					} else {
						res.headers[route.parameters[i].fieldName] = to!string(params[i]);
					}
				}
			}
		}

		try {
			import vibe.internal.meta.funcattr;

			static if (is(RT == void)) {
				__traits(getMember, inst, Method)(params);
				returnHeaders();
				res.writeJsonBody(Json.emptyObject);
			} else {
				auto ret = __traits(getMember, inst, Method)(params);
				ret = evaluateOutputModifiers!Func(ret, req, res);
				returnHeaders();
				res.writeJsonBody(ret);
			}
		} catch (HTTPStatusException e) {
			if (res.headerWritten)
				logDebug("Response already started when a HTTPStatusException was thrown. Client will not receive the proper error code (%s)!", e.status);
			else {
				returnHeaders();
				res.writeJsonBody([ "statusMessage": e.msg ], e.status);
			}
		} catch (Exception e) {
			// TODO: better error description!
			logDebug("REST handler exception: %s", e.toString());
			if (res.headerWritten) logDebug("Response already started. Client will not receive an error code!");
			else
			{
				returnHeaders();
				res.writeJsonBody(
					[ "statusMessage": e.msg, "statusDebugMessage": sanitizeUTF8(cast(ubyte[])e.toString()) ],
					HTTPStatus.internalServerError
					);
			}
		}
	}

	return &handler;
}

/**
 * Generate an handler that will wrap the server's method
 *
 * This function returns an handler that handles the http OPTIONS method.
 *
 * It will return the ALLOW header with all the methods on this resource
 * And it will handle Preflight CORS.
 *
 * Params:
 *	routes = a range of Routes were each route has the same resource/URI
 *				just different method.
 *	settings = REST server configuration.
 *
 * Returns:
 *	A delegate suitable to use as an handler for an HTTP request.
 */
private HTTPServerRequestDelegate optionsMethodHandler(RouteRange)(RouteRange routes, RestInterfaceSettings settings = null)
{
	import vibe.http.server : HTTPServerRequest, HTTPServerResponse;
	import std.algorithm : map, joiner, any;
	import std.conv : text;
	import std.array : array;
	import vibe.http.common : httpMethodString, httpMethodFromString;
	// NOTE: don't know what is better, to keep this in memory, or generate on each request
	auto allow = routes.map!(r => r.method.httpMethodString).joiner(",").text();
	auto methods = routes.map!(r => r.method).array();

	void handlePreflightedCors(HTTPServerRequest req, HTTPServerResponse res, ref HTTPMethod[] methods, RestInterfaceSettings settings = null)
	{
		import std.algorithm : among;
		import std.uni : sicmp;

		auto origin = "Origin" in req.headers;
		if (origin is null)
			return;

		if (settings !is null &&
			settings.allowedOrigins.length != 0 &&
			!settings.allowedOrigins.any!(org => org.sicmp((*origin)) == 0))
			return;

		auto method = "Access-Control-Request-Method" in req.headers;
		if (method is null)
			return;

		auto httpMethod = httpMethodFromString(*method);

		if (!methods.any!(m => m == httpMethod))
			return;

		res.headers["Access-Control-Allow-Origin"] = *origin;

		// there is no way to know if the specific resource supports credentials
		// (either cookies, HTTP authentication, or client-side SSL certificates),
		// so we always assume it does
		res.headers["Access-Control-Allow-Credentials"] = "true";
		res.headers["Access-Control-Max-Age"] = "1728000";
		res.headers["Access-Control-Allow-Methods"] = *method;

		// we have no way to reliably determine what headers the resource allows
		// so we simply copy whatever the client requested
		if (auto headers = "Access-Control-Request-Headers" in req.headers)
			res.headers["Access-Control-Allow-Headers"] = *headers;
	}

	void handler(HTTPServerRequest req, HTTPServerResponse res)
	{
		// since this is a OPTIONS request, we have to return the ALLOW headers to tell which methods we have
		res.headers["Allow"] = allow;

		// handle CORS preflighted requests
		handlePreflightedCors(req,res,methods,settings);

		// NOTE: besides just returning the allowed methods and handling CORS preflighted requests,
		// this would be a nice place to describe what kind of resources are on this route,
		// the params each accepts, the headers, etc... think WSDL but then for REST.
		res.writeBody("");
	}
	return &handler;
}

private string generateRestClientMethods(I)()
{
	import std.array : join;
	import std.string : format;
	import std.traits : fullyQualifiedName, isInstanceOf;

	alias Info = RestInterface!I;

	string ret = q{
		import vibe.internal.meta.codegen : CloneFunction;
	};

	// generate sub interface methods
	foreach (i, SI; Info.SubInterfaceTypes) {
		alias F = Info.SubInterfaceFunctions[i];
		alias RT = ReturnType!F;
		alias ParamNames = ParameterIdentifierTuple!F;
		static if (ParamNames.length == 0) enum pnames = "";
		else enum pnames = ", " ~ [ParamNames].join(", ");
		static if (isInstanceOf!(Collection, RT)) {
			ret ~= q{
					mixin CloneFunction!(Info.SubInterfaceFunctions[%1$s], q{
						return Collection!(%2$s)(m_subInterfaces[%1$s]%3$s);
					});
				}.format(i, fullyQualifiedName!SI, pnames);
		} else {
			ret ~= q{
					mixin CloneFunction!(Info.SubInterfaceFunctions[%1$s], q{
						return m_subInterfaces[%1$s];
					});
				}.format(i);
		}
	}

	// generate route methods
	foreach (i, F; Info.RouteFunctions) {
		alias ParamNames = ParameterIdentifierTuple!F;
		static if (ParamNames.length == 0) enum pnames = "";
		else enum pnames = ", " ~ [ParamNames].join(", ");

		ret ~= q{
				mixin CloneFunction!(Info.RouteFunctions[%1$s], q{
					return executeClientMethod!(I, %1$s%2$s)(*m_intf, m_requestFilter);
				});
			}.format(i, pnames);
	}

	return ret;
}


private auto executeClientMethod(I, size_t ridx, ARGS...)
	(in ref RestInterface!I intf, void delegate(HTTPClientRequest) request_filter)
{
	import vibe.web.internal.rest.common : ParameterKind;
	import vibe.textfilter.urlencode : filterURLEncode, urlEncode;
	import std.array : appender;

	alias Info = RestInterface!I;
	alias Func = Info.RouteFunctions[ridx];
	alias RT = ReturnType!Func;
	alias PTT = ParameterTypeTuple!Func;
	enum sroute = Info.staticRoutes[ridx];
	auto route = intf.routes[ridx];

	InetHeaderMap headers;
	InetHeaderMap reqhdrs;
	InetHeaderMap opthdrs;

	string url_prefix;

	auto query = appender!string();
	auto jsonBody = Json.emptyObject;
	string body_;

	void addQueryParam(size_t i)(string name)
	{
		if (query.data.length) query.put('&');
		query.filterURLEncode(name);
		query.put("=");
		static if (is(PT == Json))
			query.filterURLEncode(ARGS[i].toString());
		else // Note: CTFE triggers compiler bug here (think we are returning Json, not string).
			query.filterURLEncode(toRestString(serializeToJson(ARGS[i])));
	}

	foreach (i, PT; PTT) {
		enum sparam = sroute.parameters[i];
		auto fieldname = route.parameters[i].fieldName;
		static if (sparam.kind == ParameterKind.query) {
			addQueryParam!i(fieldname);
		} else static if (sparam.kind == ParameterKind.body_) {
			jsonBody[fieldname] = serializeToJson(ARGS[i]);
		} else static if (sparam.kind == ParameterKind.header) {
			// Don't send 'out' parameter, as they should be default init anyway and it might confuse some server
			static if (sparam.isIn) {
				static if (isInstanceOf!(Nullable, PT)) {
					if (!ARGS[i].isNull)
						headers[fieldname] = to!string(ARGS[i]);
				} else headers[fieldname] = to!string(ARGS[i]);
			}
			static if (sparam.isOut) {
				// Optional parameter
				static if (isInstanceOf!(Nullable, PT)) {
					opthdrs[fieldname] = null;
				} else {
					reqhdrs[fieldname] = null;
				}
			}
		}
	}

	debug body_ = jsonBody.toPrettyString();
	else body_ = jsonBody.toString();

	string url;
	foreach (i, p; route.fullPathParts) {
		if (p.isParameter) {
			switch (p.text) {
				foreach (j, PT; PTT) {
					case sroute.parameters[j].name:
						url ~= urlEncode(toRestString(serializeToJson(ARGS[j])));
						goto sbrk;
				}
				default: url ~= ":" ~ p.text; break;
			}
			sbrk:;
		} else url ~= p.text;
	}

	scope (exit) {
		foreach (i, PT; PTT) {
			enum sparam = sroute.parameters[i];
			auto fieldname = route.parameters[i].fieldName;
			static if (sparam.kind == ParameterKind.header) {
				static if (sparam.isOut) {
					static if (isInstanceOf!(Nullable, PT)) {
						ARGS[i] = to!(TemplateArgsOf!PT)(
							opthdrs.get(fieldname, null));
					} else {
						if (auto ptr = fieldname in reqhdrs)
							ARGS[i] = to!PT(*ptr);
					}
				}
			}
		}
	}

	auto jret = request(URL(intf.baseURL), request_filter, sroute.method, url, headers, query.data, body_, reqhdrs, opthdrs, intf.settings.httpClientSettings);

	static if (!is(RT == void))
		return deserializeJson!RT(jret);
}


import vibe.http.client : HTTPClientRequest;
/**
 * Perform a request to the interface using the given parameters.
 *
 * Params:
 * verb = Kind of request (See $(D HTTPMethod) enum).
 * name = Location to request. For a request on https://github.com/rejectedsoftware/vibe.d/issues?q=author%3ASantaClaus,
 *		it will be '/rejectedsoftware/vibe.d/issues'.
 * hdrs = The headers to send. Some field might be overriden (such as Content-Length). However, Content-Type will NOT be overriden.
 * query = The $(B encoded) query string. For a request on https://github.com/rejectedsoftware/vibe.d/issues?q=author%3ASantaClaus,
 *		it will be 'author%3ASantaClaus'.
 * body_ = The body to send, as a string. If a Content-Type is present in $(D hdrs), it will be used, otherwise it will default to
 *		the generic type "application/json".
 * reqReturnHdrs = A map of required return headers.
 *				   To avoid returning unused headers, nothing is written
 *				   to this structure unless there's an (usually empty)
 *				   entry (= the key exists) with the same key.
 *				   If any key present in `reqReturnHdrs` is not present
 *				   in the response, an Exception is thrown.
 * optReturnHdrs = A map of optional return headers.
 *				   This behaves almost as exactly as reqReturnHdrs,
 *				   except that non-existent key in the response will
 *				   not cause it to throw, but rather to set this entry
 *				   to 'null'.
 *
 * Returns:
 *     The Json object returned by the request
 */
private Json request(URL base_url,
	void delegate(HTTPClientRequest) request_filter, HTTPMethod verb,
	string path, in ref InetHeaderMap hdrs, string query, string body_,
	ref InetHeaderMap reqReturnHdrs, ref InetHeaderMap optReturnHdrs,
	in HTTPClientSettings http_settings)
{
	import vibe.http.client : HTTPClientRequest, HTTPClientResponse, requestHTTP;
	import vibe.http.common : HTTPStatusException, HTTPStatus, httpMethodString, httpStatusText;
	import vibe.inet.url : Path;

	URL url = base_url;
	url.pathString = path;

	if (query.length) url.queryString = query;

	Json ret;

	auto reqdg = (scope HTTPClientRequest req) {
		req.method = verb;
		foreach (k, v; hdrs)
			req.headers[k] = v;

		if (request_filter) request_filter(req);

		if (body_ != "")
			req.writeBody(cast(ubyte[])body_, hdrs.get("Content-Type", "application/json"));
	};

	auto resdg = (scope HTTPClientResponse res) {
		ret = res.readJson();

		logDebug(
			 "REST call: %s %s -> %d, %s",
			 httpMethodString(verb),
			 url.toString(),
			 res.statusCode,
			 ret.toString()
			 );

		// Get required headers - Don't throw yet
		string[] missingKeys;
		foreach (k, ref v; reqReturnHdrs)
			if (auto ptr = k in res.headers)
				v = (*ptr).idup;
			else
				missingKeys ~= k;

		// Get optional headers
		foreach (k, ref v; optReturnHdrs)
			if (auto ptr = k in res.headers)
				v = (*ptr).idup;
			else
				v = null;

		if (missingKeys.length)
			throw new Exception(
				"REST interface mismatch: Missing required header field(s): "
				~ missingKeys.to!string);


		if (!isSuccessCode(cast(HTTPStatus)res.statusCode))
			throw new RestException(res.statusCode, ret);
	};

	if (http_settings) requestHTTP(url, reqdg, resdg, http_settings);
	else requestHTTP(url, reqdg, resdg);

	return ret;
}

private {
	import vibe.data.json;
	import std.conv : to;

	string toRestString(Json value)
	{
		switch (value.type) {
			default: return value.toString();
			case Json.Type.Bool: return value.get!bool ? "true" : "false";
			case Json.Type.Int: return to!string(value.get!long);
			case Json.Type.Float: return to!string(value.get!double);
			case Json.Type.String: return value.get!string;
		}
	}

	T fromRestString(T)(string value)
	{
		import std.conv : ConvException;
		import vibe.web.common : HTTPStatusException, HTTPStatus;
		try {
			static if (isInstanceOf!(Nullable, T)) return T(fromRestString!(typeof(T.init.get()))(value));
			else static if (is(T == bool)) return value == "true";
			else static if (is(T : int)) return to!T(value);
			else static if (is(T : double)) return to!T(value); // FIXME: formattedWrite(dst, "%.16g", json.get!double);
			else static if (is(string : T)) return value;
			else static if (__traits(compiles, T.fromISOExtString("hello"))) return T.fromISOExtString(value);
			else static if (__traits(compiles, T.fromString("hello"))) return T.fromString(value);
			else return deserializeJson!T(parseJson(value));
		} catch (ConvException e) {
			throw new HTTPStatusException(HTTPStatus.badRequest, e.msg);
		} catch (JSONException e) {
			throw new HTTPStatusException(HTTPStatus.badRequest, e.msg);
		}
	}

	// Converting from invalid JSON string to aggregate should throw bad request
	unittest {
		import vibe.web.common : HTTPStatusException, HTTPStatus;

		void assertHTTPStatus(E)(lazy E expression, HTTPStatus expectedStatus,
			string file = __FILE__, size_t line = __LINE__)
		{
			import core.exception : AssertError;
			import std.format : format;

			try
				expression();
			catch (HTTPStatusException e)
			{
				if (e.status != expectedStatus)
					throw new AssertError(format("assertHTTPStatus failed: " ~
						"status expected %d but was %d", expectedStatus, e.status),
						file, line);

				return;
			}

			throw new AssertError("assertHTTPStatus failed: No " ~
				"'HTTPStatusException' exception was thrown", file, line);
		}

		struct Foo { int bar; }
		assertHTTPStatus(fromRestString!(Foo)("foo"), HTTPStatus.badRequest);
	}
}

private string generateModuleImports(I)()
{
	if (!__ctfe)
		assert (false);

	import vibe.internal.meta.codegen : getRequiredImports;
	import std.algorithm : map;
	import std.array : join;

	auto modules = getRequiredImports!I();
	return join(map!(a => "static import " ~ a ~ ";")(modules), "\n");
}

version(unittest)
{
	private struct Aggregate { }
	private interface Interface
	{
		Aggregate[] foo();
	}
}

unittest
{
	enum imports = generateModuleImports!Interface;
	static assert (imports == "static import vibe.web.rest;");
}

// Check that the interface is valid. Every checks on the correctness of the
// interface should be put in checkRestInterface, which allows to have consistent
// errors in the server and client.
package string getInterfaceValidationError(I)()
out (result) { assert((result is null) == !result.length); }
body {
	import vibe.web.internal.rest.common : ParameterKind;
	import std.typetuple : TypeTuple;
	import std.algorithm : strip;

	// The hack parameter is to kill "Statement is not reachable" warnings.
	string validateMethod(alias Func)(bool hack = true) {
		import vibe.internal.meta.uda;
		import std.string : format;

		static assert(is(FunctionTypeOf!Func), "Internal error");

		if (!__ctfe)
			assert(false, "Internal error");

		enum FuncId = (fullyQualifiedName!I~ "." ~ __traits(identifier, Func));
		alias PT = ParameterTypeTuple!Func;
		static if (!__traits(compiles, ParameterIdentifierTuple!Func)) {
			if (hack) return "%s: A parameter has no name.".format(FuncId);
			alias PN = TypeTuple!("-DummyInvalid-");
		} else
			alias PN = ParameterIdentifierTuple!Func;
		alias WPAT = UDATuple!(WebParamAttribute, Func);

		// Check if there is no orphan UDATuple (e.g. typo while writing the name of the parameter).
		foreach (i, uda; WPAT) {
			// Note: static foreach gets unrolled, generating multiple nested sub-scope.
			// The spec / DMD doesn't like when you have the same symbol in those,
			// leading to wrong codegen / wrong template being reused.
			// That's why those templates need different names.
			// See DMD bug #9748.
			mixin(GenOrphan!(i).Decl);
			// template CmpOrphan(string name) { enum CmpOrphan = (uda.identifier == name); }
			static if (!anySatisfy!(mixin(GenOrphan!(i).Name), PN)) {
				if (hack) return "%s: No parameter '%s' (referenced by attribute @%sParam)"
					.format(FuncId, uda.identifier, uda.origin);
			}
		}

		foreach (i, P; PT) {
			static if (!PN[i].length)
				if (hack) return "%s: Parameter %d has no name."
					.format(FuncId, i);
			// Check for multiple origins
			static if (WPAT.length) {
				// It's okay to reuse GenCmp, as the order of params won't change.
				// It should/might not be reinstantiated by the compiler.
				mixin(GenCmp!("Loop", i, PN[i]).Decl);
				alias WPA = Filter!(mixin(GenCmp!("Loop", i, PN[i]).Name), WPAT);
				static if (WPA.length > 1)
					if (hack) return "%s: Parameter '%s' has multiple @*Param attributes on it."
						.format(FuncId, PN[i]);
			}
		}

		// Check for misplaced ref / out
		alias PSC = ParameterStorageClass;
		foreach (i, SC; ParameterStorageClassTuple!Func) {
			static if (SC & PSC.out_ || SC & PSC.ref_) {
				mixin(GenCmp!("Loop", i, PN[i]).Decl);
				alias Attr
					= Filter!(mixin(GenCmp!("Loop", i, PN[i]).Name), WPAT);
				static if (Attr.length != 1) {
					if (hack) return "%s: Parameter '%s' cannot be %s"
						.format(FuncId, PN[i], SC & PSC.out_ ? "out" : "ref");
				} else static if (Attr[0].origin != ParameterKind.header) {
					if (hack) return "%s: %s parameter '%s' cannot be %s"
						.format(FuncId, Attr[0].origin, PN[i],
							SC & PSC.out_ ? "out" : "ref");
				}
			}
		}

		// Check for @path(":name")
		enum pathAttr = findFirstUDA!(PathAttribute, Func);
		static if (pathAttr.found) {
			static if (!pathAttr.value.length) {
				if (hack)
					return "%s: Path is null or empty".format(FuncId);
			} else {
				import std.algorithm : canFind, splitter;
				// splitter doesn't work with alias this ?
				auto str = pathAttr.value.data;
				if (str.canFind("//")) return "%s: Path '%s' contains empty entries.".format(FuncId, pathAttr.value);
				str = str.strip('/');
				foreach (elem; str.splitter('/')) {
					assert(elem.length, "Empty path entry not caught yet!?");

					if (elem[0] == ':') {
						// typeof(PN) is void when length is 0.
						static if (!PN.length) {
							if (hack)
								return "%s: Path contains '%s', but no parameter '_%s' defined."
									.format(FuncId, elem, elem[1..$]);
						} else {
							if (![PN].canFind("_"~elem[1..$]))
								if (hack) return "%s: Path contains '%s', but no parameter '_%s' defined."
									.format(FuncId, elem, elem[1..$]);
							elem = elem[1..$];
						}
					}
				}
				// TODO: Check for validity of the subpath.
			}
		}
		return null;
	}

	if (!__ctfe)
		assert(false, "Internal error");
	bool hack = true;
	foreach (method; __traits(allMembers, I)) {
		// WORKAROUND #1045 / @@BUG14375@@
		static if (method.length != 0)
			foreach (overload; MemberFunctionsTuple!(I, method)) {
				static if (validateMethod!(overload)())
					if (hack) return validateMethod!(overload)();
			}
	}
	return null;
}

// Test detection of user typos (e.g., if the attribute is on a parameter that doesn't exist).
unittest {
	enum msg = "No parameter 'ath' (referenced by attribute @headerParam)";

	interface ITypo {
		@headerParam("ath", "Authorization") // mistyped parameter name
		string getResponse(string auth);
	}
	enum err = getInterfaceValidationError!ITypo;
	static assert(err !is null && stripTestIdent(err) == msg,
		"Expected validation error for getResponse, got: "~stripTestIdent(err));
}

// Multiple origin for a parameter
unittest {
	enum msg = "Parameter 'arg1' has multiple @*Param attributes on it.";

	interface IMultipleOrigin {
		@headerParam("arg1", "Authorization") @bodyParam("arg1", "Authorization")
		string getResponse(string arg1, int arg2);
	}
	enum err = getInterfaceValidationError!IMultipleOrigin;
	static assert(err !is null && stripTestIdent(err) == msg, err);
}

// Missing parameter name
unittest {
	static if (__VERSION__ < 2067)
		enum msg = "A parameter has no name.";
	else
		enum msg = "Parameter 0 has no name.";

	interface IMissingName1 {
		string getResponse(string = "troublemaker");
	}
	interface IMissingName2 {
		string getResponse(string);
	}
	enum err1 = getInterfaceValidationError!IMissingName1;
	static assert(err1 !is null && stripTestIdent(err1) == msg, err1);
	enum err2 = getInterfaceValidationError!IMissingName2;
	static assert(err2 !is null && stripTestIdent(err2) == msg, err2);
}

// Issue 949
unittest {
	enum msg = "Path contains ':owner', but no parameter '_owner' defined.";

	@path("/repos/")
	interface IGithubPR {
		@path(":owner/:repo/pulls")
		string getPullRequests(string owner, string repo);
	}
	enum err = getInterfaceValidationError!IGithubPR;
	static assert(err !is null && stripTestIdent(err) == msg, err);
}

// Issue 1017
unittest {
	interface TestSuccess { @path("/") void test(); }
	interface TestSuccess2 { @path("/test/") void test(); }
	interface TestFail { @path("//") void test(); }
	interface TestFail2 { @path("/test//it/") void test(); }
	static assert(getInterfaceValidationError!TestSuccess is null);
	static assert(getInterfaceValidationError!TestSuccess2 is null);
	static assert(stripTestIdent(getInterfaceValidationError!TestFail)
		== "Path '//' contains empty entries.");
	static assert(stripTestIdent(getInterfaceValidationError!TestFail2)
		== "Path '/test//it/' contains empty entries.");
}

unittest {
	interface NullPath  { @path(null) void test(); }
	interface ExplicitlyEmptyPath { @path("") void test(); }
	static assert(stripTestIdent(getInterfaceValidationError!NullPath)
				  == "Path is null or empty");
	static assert(stripTestIdent(getInterfaceValidationError!ExplicitlyEmptyPath)
				  == "Path is null or empty");

	// Note: Implicitly empty path are valid:
	// interface ImplicitlyEmptyPath { void get(); }
}

// Accept @headerParam ref / out parameters
unittest {
	interface HeaderRef {
		@headerParam("auth", "auth")
		string getData(ref string auth);
	}
	static assert(getInterfaceValidationError!HeaderRef is null,
		      stripTestIdent(getInterfaceValidationError!HeaderRef));

	interface HeaderOut {
		@headerParam("auth", "auth")
		void getData(out string auth);
	}
	static assert(getInterfaceValidationError!HeaderOut is null,
		      stripTestIdent(getInterfaceValidationError!HeaderOut));
}

// Reject unattributed / @queryParam or @bodyParam ref / out parameters
unittest {
	interface QueryRef {
		@queryParam("auth", "auth")
		string getData(ref string auth);
	}
	static assert(stripTestIdent(getInterfaceValidationError!QueryRef)
		== "query parameter 'auth' cannot be ref");

	interface QueryOut {
		@queryParam("auth", "auth")
		void getData(out string auth);
	}
	static assert(stripTestIdent(getInterfaceValidationError!QueryOut)
		== "query parameter 'auth' cannot be out");

	interface BodyRef {
		@bodyParam("auth", "auth")
		string getData(ref string auth);
	}
	static assert(stripTestIdent(getInterfaceValidationError!BodyRef)
		== "body_ parameter 'auth' cannot be ref");

	interface BodyOut {
		@bodyParam("auth", "auth")
		void getData(out string auth);
	}
	static assert(stripTestIdent(getInterfaceValidationError!BodyOut)
		== "body_ parameter 'auth' cannot be out");

	// There's also the possibility of someone using an out unnamed
	// parameter (don't ask me why), but this is catched as unnamed
	// parameter, so we don't need to check it here.
}

private string stripTestIdent(string msg) {
	static if (__VERSION__ <= 2066) {
		import vibe.utils.string;
		auto idx = msg.indexOfCT(": ");
	} else {
		import std.string;
		auto idx = msg.indexOf(": ");
	}
	return idx >= 0 ? msg[idx+2 .. $] : msg;
}

// Small helper for client code generation
private string paramCTMap(string[string] params)
{
	import std.array : appender, join;
	if (!__ctfe)
		assert (false, "This helper is only supposed to be called for codegen in RestClientInterface.");
	auto app = appender!(string[]);
	foreach (key, val; params) {
		app ~= "\""~key~"\"";
		app ~= val;
	}
	return app.data.join(", ");
}

package string stripTUnderscore(string name, RestInterfaceSettings settings) {
	if ((settings is null || settings.stripTrailingUnderscore)
	    && name.endsWith("_"))
		return name[0 .. $-1];
	else return name;
}

// Workarounds @@DMD:9748@@, and maybe more
package template GenCmp(string name, int id, string cmpTo) {
	import std.string : format;
	import std.conv : to;
	enum Decl = q{
		template %1$s(alias uda) {
			enum %1$s = (uda.identifier == "%2$s");
		}
	}.format(Name, cmpTo);
	enum Name = name~to!string(id);
}

// Ditto
private template GenOrphan(int id) {
	import std.string : format;
	import std.conv : to;
	enum Decl = q{
		template %1$s(string name) {
			enum %1$s = (uda.identifier == name);
		}
	}.format(Name);
	enum Name = "OrphanCheck"~to!string(id);
}

// Workaround for issue #1045 / DMD bug 14375
// Also, an example of policy-based design using this module.
unittest {
	import std.traits, std.typetuple;
	import vibe.internal.meta.codegen;
	import vibe.internal.meta.typetuple;
	import vibe.web.internal.rest.common : ParameterKind;

	interface Policies {
		@headerParam("auth", "Authorization")
		string BasicAuth(string auth, ulong expiry);
	}

	@path("/keys/")
	interface IKeys(alias AuthenticationPolicy = Policies.BasicAuth) {
		static assert(is(FunctionTypeOf!AuthenticationPolicy == function),
			      "Policies needs to be functions");
		@path("/") @method(HTTPMethod.POST)
		mixin CloneFunctionDecl!(AuthenticationPolicy, true, "create");
	}

	class KeysImpl : IKeys!() {
	override:
		string create(string auth, ulong expiry) {
			return "4242-4242";
		}
	}

	// Some sanity checks
        // Note: order is most likely implementation dependent.
	// Good thing we only have one frontend...
	alias WPA = WebParamAttribute;
	static assert(Compare!(
			      Group!(__traits(getAttributes, IKeys!().create)),
			      Group!(PathAttribute("/"),
				     MethodAttribute(HTTPMethod.POST),
				     WPA(ParameterKind.header, "auth", "Authorization"))));

	void register() {
		auto router = new URLRouter();
		router.registerRestInterface(new KeysImpl());
	}

	void query() {
		auto client = new RestInterfaceClient!(IKeys!())("http://127.0.0.1:8080");
		assert(client.create("Hello", 0) == "4242-4242");
	}
}
