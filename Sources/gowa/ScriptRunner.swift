import Foundation
import JavaScriptCore

struct OCScript: Equatable, Sendable {
    var type: String // "before-request" | "after-response" | "tests"
    var code: String
}

struct ScriptTestResult: Sendable, Equatable {
    var name: String
    var passed: Bool
    var error: String?
}

struct ScriptLog: Sendable, Equatable {
    var level: String
    var message: String
}

/// Mutable request view handed to before-request scripts.
struct ScriptRequest: Sendable, Equatable {
    var name: String
    var method: String
    var url: String
    var headers: [OCHeader]
    var body: String
}

/// What one script phase produced.
struct ScriptOutcome: Sendable {
    var request: ScriptRequest?
    var runtimeVariables: [String: String] = [:]
    var environmentVariables: [String: String] = [:]
    var tests: [ScriptTestResult] = []
    var logs: [ScriptLog] = []
    var error: String?
}

/// Runs collection, folder, and request scripts in JavaScriptCore with a
/// Bruno-compatible API (`req`, `res`, `bru`, `test`, `expect`). Scripts get
/// no file or network access, and each run stops after a time limit.
@MainActor
enum ScriptRunner {
    static let timeLimit: Double = 5

    static func run(
        _ scripts: [OCScript],
        request: ScriptRequest?,
        response: HTTPResult?,
        variables: [String: String],
        timeLimit: Double = timeLimit
    ) -> ScriptOutcome {
        var outcome = ScriptOutcome(request: request)
        guard !scripts.isEmpty, let context = JSContext() else { return outcome }
        limitExecution(context, seconds: timeLimit)

        var currentVariables = variables
        let state = ScriptState()
        state.request = request

        context.exceptionHandler = { _, exception in
            state.exception = exception?.toString()
            if let stack = exception?.objectForKeyedSubscript("stack")?.toString(), stack != "undefined" {
                state.exception = (state.exception ?? "") + "\n" + stack
            }
        }

        let log: @convention(block) (String, JSValue) -> Void = { level, args in
            let count = Int(args.objectForKeyedSubscript("length")?.toInt32() ?? 0)
            let parts = (0..<count).map { index -> String in
                let item = args.objectAtIndexedSubscript(index)!
                if item.isString || item.isBoolean || item.isNumber || item.isUndefined || item.isNull { return item.toString() }
                if let object = item.toObject(), JSONSerialization.isValidJSONObject(object),
                   let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
                    return String(data: data, encoding: .utf8) ?? item.toString()
                }
                return item.toString()
            }
            state.logs.append(ScriptLog(level: level, message: parts.joined(separator: " ")))
        }
        context.setObject(log, forKeyedSubscript: "__log" as NSString)

        let getVar: @convention(block) (String) -> Any = { name in
            (state.runtime[name] ?? currentVariables[name]).map { $0 as Any } ?? NSNull()
        }
        let setVar: @convention(block) (String, JSValue) -> Void = { name, value in
            state.runtime[name] = Self.text(value)
        }
        let getEnvVar: @convention(block) (String) -> Any = { name in
            (state.environment[name] ?? variables[name]).map { $0 as Any } ?? NSNull()
        }
        let setEnvVar: @convention(block) (String, JSValue) -> Void = { name, value in
            state.environment[name] = Self.text(value)
        }
        let interpolate: @convention(block) (String) -> String = { template in
            var merged = currentVariables
            merged.merge(state.environment) { _, new in new }
            merged.merge(state.runtime) { _, new in new }
            return OpenCollectionDocument.interpolate(template, merged)
        }
        let recordTest: @convention(block) (String, Bool, JSValue) -> Void = { name, passed, error in
            state.tests.append(ScriptTestResult(name: name, passed: passed, error: error.isUndefined || error.isNull ? nil : error.toString()))
        }
        context.setObject(getVar, forKeyedSubscript: "__getVar" as NSString)
        context.setObject(setVar, forKeyedSubscript: "__setVar" as NSString)
        context.setObject(getEnvVar, forKeyedSubscript: "__getEnvVar" as NSString)
        context.setObject(setEnvVar, forKeyedSubscript: "__setEnvVar" as NSString)
        context.setObject(interpolate, forKeyedSubscript: "__interpolate" as NSString)
        context.setObject(recordTest, forKeyedSubscript: "__recordTest" as NSString)

        context.setObject(requestObject(request), forKeyedSubscript: "__request" as NSString)
        context.setObject(responseObject(response), forKeyedSubscript: "__response" as NSString)
        context.evaluateScript(prelude)

        for script in scripts where !script.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.exception = nil
            context.evaluateScript("(function() {\n\(script.code)\n})();")
            if let exception = state.exception {
                outcome.error = "\(script.type) script: \(exception)"
                break
            }
            currentVariables.merge(state.runtime) { _, new in new }
        }

        if request != nil, let updated = context.objectForKeyedSubscript("__request")?.toDictionary() {
            outcome.request = Self.request(from: updated, fallback: request!)
        }
        outcome.runtimeVariables = state.runtime
        outcome.environmentVariables = state.environment
        outcome.tests = state.tests
        outcome.logs = state.logs
        return outcome
    }

    private final class ScriptState {
        var request: ScriptRequest?
        var runtime: [String: String] = [:]
        var environment: [String: String] = [:]
        var tests: [ScriptTestResult] = []
        var logs: [ScriptLog] = []
        var exception: String?
    }

    private static func text(_ value: JSValue) -> String {
        if value.isString { return value.toString() }
        if value.isObject, let data = try? JSONSerialization.data(withJSONObject: value.toObject() as Any, options: [.sortedKeys, .fragmentsAllowed]) {
            return String(data: data, encoding: .utf8) ?? value.toString()
        }
        return value.toString()
    }

    private static func requestObject(_ request: ScriptRequest?) -> Any {
        guard let request else { return NSNull() }
        return [
            "name": request.name,
            "method": request.method,
            "url": request.url,
            "headers": request.headers.map { ["name": $0.name, "value": $0.value, "disabled": $0.disabled] },
            "body": request.body,
        ] as [String: Any]
    }

    private static func request(from dict: [AnyHashable: Any], fallback: ScriptRequest) -> ScriptRequest {
        var request = fallback
        request.method = dict["method"] as? String ?? fallback.method
        request.url = dict["url"] as? String ?? fallback.url
        request.body = dict["body"] as? String ?? fallback.body
        if let headers = dict["headers"] as? [[String: Any]] {
            request.headers = headers.map {
                OCHeader(name: $0["name"] as? String ?? "", value: "\($0["value"] ?? "")", disabled: $0["disabled"] as? Bool ?? false)
            }
        }
        return request
    }

    private static func responseObject(_ response: HTTPResult?) -> Any {
        guard let response else { return NSNull() }
        var headers: [String: String] = [:]
        for header in response.headers { headers[header.name.lowercased()] = header.value }
        return [
            "status": response.status,
            "statusText": response.statusPhrase,
            "headers": headers,
            "text": String(data: response.body, encoding: .utf8) ?? "",
            "responseTime": response.elapsed.milliseconds,
            "url": response.finalURL.absoluteString,
        ] as [String: Any]
    }

    private typealias SetLimit = @convention(c) (
        JSContextGroupRef, Double, (@convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool)?, UnsafeMutableRawPointer?
    ) -> Void

    /// JavaScriptCore exports a watchdog that is not in its public headers;
    /// without it a `while (true) {}` would hang the app.
    private static func limitExecution(_ context: JSContext, seconds: Double) {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else { return }
        let setLimit = unsafeBitCast(symbol, to: SetLimit.self)
        setLimit(JSContextGetGroup(context.jsGlobalContextRef), seconds, { _, _ in true }, nil)
    }

    private static let prelude = #"""
    var console = {
      log: function() { __log("log", Array.prototype.slice.call(arguments)); },
      info: function() { __log("info", Array.prototype.slice.call(arguments)); },
      warn: function() { __log("warn", Array.prototype.slice.call(arguments)); },
      error: function() { __log("error", Array.prototype.slice.call(arguments)); },
    };

    function __headerIndex(name) {
      var lower = String(name).toLowerCase();
      for (var i = 0; i < __request.headers.length; i++) {
        if (__request.headers[i].name.toLowerCase() === lower) return i;
      }
      return -1;
    }

    var req = __request === null ? undefined : {
      getName: function() { return __request.name; },
      getUrl: function() { return __request.url; },
      setUrl: function(url) { __request.url = String(url); },
      getMethod: function() { return __request.method; },
      setMethod: function(method) { __request.method = String(method).toUpperCase(); },
      getHeader: function(name) { var i = __headerIndex(name); return i < 0 ? undefined : __request.headers[i].value; },
      getHeaders: function() {
        var out = {};
        __request.headers.forEach(function(h) { if (!h.disabled) out[h.name] = h.value; });
        return out;
      },
      setHeader: function(name, value) {
        var i = __headerIndex(name);
        if (i < 0) __request.headers.push({ name: String(name), value: String(value), disabled: false });
        else { __request.headers[i].value = String(value); __request.headers[i].disabled = false; }
      },
      deleteHeader: function(name) { var i = __headerIndex(name); if (i >= 0) __request.headers.splice(i, 1); },
      getBody: function() { try { return JSON.parse(__request.body); } catch (e) { return __request.body; } },
      setBody: function(body) { __request.body = typeof body === "string" ? body : JSON.stringify(body, null, 2); },
    };

    var res = __response === null ? undefined : (function() {
      var body;
      try { body = JSON.parse(__response.text); } catch (e) { body = __response.text; }
      var r = function(path) {
        if (!path) return body;
        return String(path).replace(/^\$\.?/, "").split(/\.|\[(\d+)\]/).filter(function(p) { return p; })
          .reduce(function(v, k) { return v == null ? undefined : v[k]; }, body);
      };
      r.status = __response.status;
      r.statusText = __response.statusText;
      r.headers = __response.headers;
      r.body = body;
      r.responseTime = __response.responseTime;
      r.url = __response.url;
      r.getStatus = function() { return __response.status; };
      r.getStatusText = function() { return __response.statusText; };
      r.getHeader = function(name) { return __response.headers[String(name).toLowerCase()]; };
      r.getHeaders = function() { return __response.headers; };
      r.getBody = function() { return body; };
      r.getResponseTime = function() { return __response.responseTime; };
      r.getUrl = function() { return __response.url; };
      return r;
    })();

    var bru = {
      getVar: function(name) { var v = __getVar(name); return v === null ? undefined : v; },
      setVar: function(name, value) { __setVar(name, value); },
      getEnvVar: function(name) { var v = __getEnvVar(name); return v === null ? undefined : v; },
      setEnvVar: function(name, value) { __setEnvVar(name, value); },
      interpolate: function(text) { return __interpolate(String(text)); },
    };
    var gowa = bru;

    function __deepEqual(a, b) {
      if (a === b) return true;
      if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return false;
      var ka = Object.keys(a), kb = Object.keys(b);
      if (ka.length !== kb.length) return false;
      return ka.every(function(k) { return __deepEqual(a[k], b[k]); });
    }

    function __show(v) { try { return JSON.stringify(v); } catch (e) { return String(v); } }

    function expect(actual) {
      var negate = false;
      var api = {};
      function check(ok, message) {
        if (negate ? ok : !ok) throw new Error((negate ? "expected not: " : "expected: ") + message);
        return api;
      }
      ["to", "be", "been", "is", "that", "which", "and", "has", "have", "with", "of", "same", "an"].forEach(function(word) {
        Object.defineProperty(api, word, { get: function() { return api; } });
      });
      Object.defineProperty(api, "not", { get: function() { negate = !negate; return api; } });
      Object.defineProperty(api, "ok", { get: function() { return check(!!actual, __show(actual) + " to be truthy"); } });
      Object.defineProperty(api, "true", { get: function() { return check(actual === true, __show(actual) + " to be true"); } });
      Object.defineProperty(api, "false", { get: function() { return check(actual === false, __show(actual) + " to be false"); } });
      Object.defineProperty(api, "null", { get: function() { return check(actual === null, __show(actual) + " to be null"); } });
      Object.defineProperty(api, "undefined", { get: function() { return check(actual === undefined, __show(actual) + " to be undefined"); } });
      Object.defineProperty(api, "empty", { get: function() {
        var size = actual == null ? 0 : (typeof actual === "object" && !Array.isArray(actual) ? Object.keys(actual).length : actual.length);
        return check(size === 0, __show(actual) + " to be empty");
      } });
      api.equal = api.equals = api.eq = function(expected) { return check(actual === expected, __show(actual) + " to equal " + __show(expected)); };
      api.eql = function(expected) { return check(__deepEqual(actual, expected), __show(actual) + " to deeply equal " + __show(expected)); };
      api.a = function(type) {
        var t = Array.isArray(actual) ? "array" : actual === null ? "null" : typeof actual;
        return check(t === String(type).toLowerCase(), __show(actual) + " to be a " + type);
      };
      api.include = api.contain = api.includes = function(item) {
        var ok = typeof actual === "string" ? actual.indexOf(item) >= 0 : Array.isArray(actual) ? actual.some(function(x) { return __deepEqual(x, item); }) : false;
        return check(ok, __show(actual) + " to include " + __show(item));
      };
      api.property = function(name, value) {
        var has = actual != null && Object.prototype.hasOwnProperty.call(actual, name);
        if (arguments.length > 1) return check(has && __deepEqual(actual[name], value), "property " + name + " to equal " + __show(value));
        return check(has, __show(actual) + " to have property " + name);
      };
      api.lengthOf = function(n) { return check(actual != null && actual.length === n, "length " + (actual && actual.length) + " to be " + n); };
      api.above = api.gt = function(n) { return check(actual > n, __show(actual) + " to be above " + n); };
      api.least = api.gte = function(n) { return check(actual >= n, __show(actual) + " to be at least " + n); };
      api.below = api.lt = function(n) { return check(actual < n, __show(actual) + " to be below " + n); };
      api.most = api.lte = function(n) { return check(actual <= n, __show(actual) + " to be at most " + n); };
      api.oneOf = function(list) { return check(list.indexOf(actual) >= 0, __show(actual) + " to be one of " + __show(list)); };
      api.match = function(re) { return check(re.test(String(actual)), __show(actual) + " to match " + re); };
      api.status = function(code) {
        var s = actual && typeof actual.getStatus === "function" ? actual.getStatus() : actual && actual.status;
        return check(s === code, "status " + s + " to be " + code);
      };
      return api;
    }

    function test(name, fn) {
      try { fn(); __recordTest(String(name), true, undefined); }
      catch (e) { __recordTest(String(name), false, e && e.message ? e.message : String(e)); }
    }
    """#
}
