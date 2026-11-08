// Reqling's script runtime: `rq`, `console`, timers, `crypto`, `btoa`/`atob`, and `require`, built over the natives the
// script runner installs as `__native` (ScriptLevelHost+Natives.swift). Every member here is documented in
// ScriptAPICatalog, and a conformance test fails when the two disagree.
'use strict';
(function (native) {
  delete globalThis.__native;
  const info = native.info();
  const phase = info.phase;
  const isPre = phase === 'preRequest';
  const isStream = phase === 'stream';

  function fail(message) {
    throw new Error(message);
  }

  /// What a `set` stores: strings as they are, `undefined` as empty, and anything else as JSON, which reads back the
  /// same way through `JSON.parse`.
  function variableText(value) {
    if (typeof value === 'string') {
      return value;
    }
    if (value === undefined) {
      return '';
    }
    if (typeof value === 'number' || typeof value === 'boolean' || typeof value === 'bigint') {
      return String(value);
    }
    return JSON.stringify(value);
  }

  // MARK: Console

  /// Objects print as indented JSON, with cycles and functions named rather than dropped; strings print as they are.
  function describe(value) {
    if (typeof value === 'string') {
      return value;
    }
    if (value instanceof Error) {
      return value.stack ? `${value.name}: ${value.message}` : String(value);
    }
    if (typeof value === 'function') {
      return `[Function ${value.name || 'anonymous'}]`;
    }
    if (typeof value === 'symbol' || typeof value === 'bigint' || value === undefined) {
      return String(value);
    }
    const seen = new WeakSet();
    try {
      const text = JSON.stringify(value, function (key, item) {
        if (typeof item === 'function') {
          return `[Function ${item.name || 'anonymous'}]`;
        }
        if (typeof item === 'bigint') {
          return String(item);
        }
        if (item === undefined) {
          return '[undefined]';
        }
        if (item !== null && typeof item === 'object') {
          if (seen.has(item)) {
            return '[Circular]';
          }
          seen.add(item);
        }
        return item;
      }, 2);
      return text === undefined ? String(value) : text;
    } catch (error) {
      return String(value);
    }
  }

  const consoleObject = {};
  for (const severity of ['log', 'info', 'warn', 'error', 'debug']) {
    consoleObject[severity] = function (...values) {
      native.log(severity, values.map(describe).join(' '));
    };
  }
  globalThis.console = Object.freeze(consoleObject);

  // MARK: Timers

  globalThis.setTimeout = function (callback, delay, ...values) {
    if (typeof callback !== 'function') {
      fail('setTimeout needs a function.');
    }
    return native.setTimer(() => callback(...values), Number(delay) || 0, false);
  };
  globalThis.setInterval = function (callback, delay, ...values) {
    if (typeof callback !== 'function') {
      fail('setInterval needs a function.');
    }
    return native.setTimer(() => callback(...values), Number(delay) || 0, true);
  };
  globalThis.clearTimeout = globalThis.clearInterval = function (id) {
    if (typeof id === 'number') {
      native.clearTimer(id);
    }
  };

  // MARK: Crypto and base64

  globalThis.btoa = (text) => native.btoa(String(text));
  globalThis.atob = (text) => native.atob(String(text));

  globalThis.crypto = Object.freeze({
    getRandomValues(array) {
      if (!ArrayBuffer.isView(array) || array instanceof Float32Array || array instanceof Float64Array) {
        throw new TypeError('crypto.getRandomValues needs an integer typed array.');
      }
      if (array.byteLength > 65536) {
        fail('crypto.getRandomValues can fill at most 65536 bytes at a time.');
      }
      new Uint8Array(array.buffer, array.byteOffset, array.byteLength).set(native.randomBytes(array.byteLength));
      return array;
    },
    randomUUID: () => native.uuid(),
  });

  function digest(algorithm) {
    return function (data, options) {
      const settings = options || {};
      return native.digest(algorithm, variableText(data), settings.inputEncoding || 'utf8', settings.encoding || 'hex');
    };
  }

  const cryptoHelpers = Object.freeze({
    md5: digest('md5'),
    sha1: digest('sha1'),
    sha256: digest('sha256'),
    sha384: digest('sha384'),
    sha512: digest('sha512'),
    hmac(algorithm, key, data, options) {
      const settings = options || {};
      return native.hmac(
        String(algorithm), variableText(key), settings.keyEncoding || 'utf8',
        variableText(data), settings.inputEncoding || 'utf8', settings.encoding || 'hex'
      );
    },
    randomUUID: () => native.uuid(),
  });

  // MARK: require

  const libraries = {};
  globalThis.require = function (name) {
    const key = String(name);
    if (Object.prototype.hasOwnProperty.call(libraries, key)) {
      return libraries[key];
    }
    const source = native.loadLibrary(key);
    const module = { exports: {} };
    // Cached before it runs, as Node does for a cyclic require: lodash reads `_` from the global object as it loads,
    // which is this getter, and would load itself again forever.
    libraries[key] = module.exports;
    new Function('module', 'exports', source)(module, module.exports);
    libraries[key] = module.exports;
    return module.exports;
  };
  Object.defineProperty(globalThis, 'CryptoJS', { get: () => globalThis.require('crypto-js'), configurable: true });
  Object.defineProperty(globalThis, '_', { get: () => globalThis.require('lodash'), configurable: true });

  // MARK: Variables

  function variableScope(scope, name) {
    const object = {
      get: (key) => native.varGet(scope, String(key)),
      set(key, value, options) {
        native.varSet(scope, String(key), variableText(value), Boolean(options && options.secret));
      },
      unset(key) {
        native.varSet(scope, String(key), null, false);
      },
      has: (key) => native.varGet(scope, String(key)) !== undefined,
      isSecret: (key) => native.varIsSecret(scope, String(key)),
      toObject: () => native.varValues(scope),
    };
    if (name !== undefined) {
      object.name = name;
    }
    return object;
  }

  const variables = variableScope('variables');
  variables.replaceIn = (text) => native.replaceIn(String(text));

  // MARK: Rows

  /// Headers ignore case, as HTTP does; query parameters don't.
  function rowList(read, target, mutable) {
    const matches = target === 'query'
      ? (name, row) => row[0] === name
      : (name, row) => row[0].toLowerCase() === name.toLowerCase();
    const list = {
      get(name) {
        const row = read().find((candidate) => matches(String(name), candidate));
        return row ? row[1] : undefined;
      },
      has: (name) => read().some((candidate) => matches(String(name), candidate)),
      all: () => read().map(([name, value]) => ({ name, value })),
      toObject() {
        const object = {};
        for (const [name, value] of read()) {
          object[name] = value;
        }
        return object;
      },
    };
    if (mutable) {
      const change = (operation, name, value) => native.requestChange(operation, target, String(name), value);
      list.upsert = (name, value) => change('upsert', name, variableText(value));
      list.add = (name, value) => change('add', name, variableText(value));
      list.remove = (name) => change('remove', name, null);
    }
    return Object.freeze(list);
  }

  // MARK: Request

  function buildRequest() {
    const template = native.request();
    const request = {
      protocol: template.protocol,
      url: template.url,
      headers: rowList(() => native.requestRows('header'), 'header', true),
    };
    if (template.protocol === 'grpc') {
      request.metadata = request.headers;
      request.service = template.service;
      request.rpc = template.rpc;
      request.messages = Object.freeze(template.messages.slice());
    } else {
      request.query = rowList(() => native.requestRows('query'), 'query', true);
    }
    if (template.protocol === 'http') {
      request.method = template.method;
      request.body = template.body === null ? null : Object.freeze({
        mode: template.body.mode,
        raw: template.body.raw,
        fields: Object.freeze(template.body.fields.map(([name, value]) => Object.freeze({ name, value }))),
        graphQL: template.body.graphQL === null ? null : Object.freeze(Object.assign({}, template.body.graphQL)),
      });
    }
    if (template.protocol === 'websocket') {
      request.messages = Object.freeze(template.messages.slice());
    }
    return Object.freeze(request);
  }

  // MARK: Response

  function parseJSON(text, what) {
    try {
      return JSON.parse(text);
    } catch (error) {
      throw new SyntaxError(`${what} isn't JSON: ${error.message}`);
    }
  }

  function staticRows(rows) {
    return rowList(() => rows, 'header', false);
  }

  // What `rq.response` lists and stream handlers get alike: `StreamEvent`, `SocketMessage`, and `GRPCMessage`.

  function eventObject(event) {
    return Object.freeze({
      id: event.id,
      event: event.event,
      data: event.data,
      retry: event.retry,
      json: () => parseJSON(event.data, 'The event\'s data'),
    });
  }

  function socketMessageObject(message) {
    return Object.freeze({
      direction: message.direction,
      text: message.text,
      isBinary: message.text === null,
      base64: message.base64,
      json: () => (message.text === null
        ? fail('A binary message isn\'t JSON.')
        : parseJSON(message.text, 'The message')),
    });
  }

  function grpcMessageObject(message) {
    return Object.freeze({
      text: () => message,
      json: () => parseJSON(message, 'The message'),
    });
  }

  /// A stream script's `rq.response`: what the stream opened with, as the rest is known only once it ends.
  function buildOpening(response) {
    switch (response.kind) {
      case 'eventStream':
        return Object.freeze({ code: response.code, status: response.status, headers: staticRows(response.headers) });
      case 'webSocket':
        return Object.freeze({ code: response.code, headers: staticRows(response.headers), subprotocol: response.subprotocol });
      case 'grpc':
        return Object.freeze({ metadata: staticRows(response.metadata) });
      default:
        return fail('Reqling sent a response this runtime doesn\'t know.');
    }
  }

  function buildResponse() {
    const response = native.response();
    if (isStream) {
      return buildOpening(response);
    }
    switch (response.kind) {
      case 'http': {
        let text;
        const body = () => (text === undefined ? (text = native.responseText()) : text);
        return Object.freeze({
          code: response.code,
          status: response.status,
          headers: staticRows(response.headers),
          size: response.size,
          truncated: response.truncated,
          responseTime: response.responseTime,
          text: body,
          json: () => parseJSON(body(), 'The response body'),
          base64: () => native.responseBase64(),
        });
      }
      case 'eventStream':
        return Object.freeze({
          code: response.code,
          status: response.status,
          headers: staticRows(response.headers),
          events: Object.freeze(response.events.map(eventObject)),
          end: response.end,
          omittedEventCount: response.omittedEventCount,
          responseTime: response.responseTime,
          text: () => '',
          json: () => fail('An event stream has no single body; read rq.response.events.'),
        });
      case 'grpc': {
        const messages = Object.freeze(response.messages.map(grpcMessageObject));
        return Object.freeze({
          code: response.status.code,
          status: Object.freeze(Object.assign({}, response.status)),
          metadata: staticRows(response.metadata),
          trailers: staticRows(response.trailers),
          messages,
          sentCount: response.sentCount,
          receivedCount: response.receivedCount,
          responseTime: response.responseTime,
          json: () => (messages.length === 0
            ? fail('The call received no message.')
            : messages[messages.length - 1].json()),
        });
      }
      case 'webSocket':
        return Object.freeze({
          code: response.code,
          headers: staticRows(response.headers),
          subprotocol: response.subprotocol,
          messages: Object.freeze(response.messages.map(socketMessageObject)),
          close: response.close === null ? null : Object.freeze(Object.assign({}, response.close)),
          end: response.end,
          responseTime: response.responseTime,
        });
      default:
        return fail('Reqling sent a response this runtime doesn\'t know.');
    }
  }

  // MARK: Cookies

  const cookieOptionNames = ['path', 'domain', 'expires', 'secure', 'httpOnly', 'sameSite'];

  /// Milliseconds since 1970 from a Date, a date string, or a number; `null` for a session cookie.
  function cookieExpiry(value) {
    if (value === undefined || value === null) {
      return null;
    }
    let time;
    if (value instanceof Date) {
      time = value.getTime();
    } else if (typeof value === 'number') {
      time = value;
    } else {
      time = Date.parse(String(value));
    }
    if (!Number.isFinite(time)) {
      fail(`A cookie's expires is a Date, a date string, or milliseconds since 1970, not ${describe(value)}.`);
    }
    return time;
  }

  /// The options as the natives take them, refusing a key no cookie has rather than ignoring it.
  function cookieOptions(options) {
    if (options === undefined || options === null) {
      options = {};
    } else if (typeof options !== 'object') {
      fail('A cookie\'s options are an object, such as { path: "/", secure: true }.');
    }
    for (const key of Object.keys(options)) {
      if (!cookieOptionNames.includes(key)) {
        fail(`A cookie has no option "${key}"; it takes ${cookieOptionNames.join(', ')}.`);
      }
    }
    const text = (value) => (value === undefined || value === null ? null : String(value));
    return {
      path: text(options.path),
      domain: text(options.domain),
      expires: cookieExpiry(options.expires),
      secure: Boolean(options.secure),
      httpOnly: Boolean(options.httpOnly),
      sameSite: text(options.sameSite),
    };
  }

  /// A cookie with its keys in a fixed order, so it prints the same way every time.
  function cookieObject(cookie) {
    return Object.freeze({
      name: cookie.name,
      value: cookie.value,
      domain: cookie.domain,
      path: cookie.path,
      expires: cookie.expires,
      secure: cookie.secure,
      httpOnly: cookie.httpOnly,
      sameSite: cookie.sameSite,
      hostOnly: cookie.hostOnly,
    });
  }

  /// The cookie methods over one scope: `null` for the request's URL, or the text `rq.cookies.for` settled on.
  function cookieMethods(scope) {
    const read = () => native.cookieRead(scope).map(cookieObject);
    const find = (name) => read().find((cookie) => cookie.name === String(name));
    return {
      get(name) {
        const cookie = find(name);
        return cookie === undefined ? undefined : cookie.value;
      },
      has: (name) => find(name) !== undefined,
      all: read,
      toObject() {
        const object = {};
        for (const cookie of read()) {
          // Defined rather than assigned, so a cookie named `__proto__` is just a key.
          if (!Object.prototype.hasOwnProperty.call(object, cookie.name)) {
            Object.defineProperty(object, cookie.name, { value: cookie.value, enumerable: true, writable: true, configurable: true });
          }
        }
        return object;
      },
      set(name, value, options) {
        native.cookieSet(scope, String(name), variableText(value), cookieOptions(options));
      },
      remove(name) {
        native.cookieRemove(scope, String(name));
      },
      clear() {
        native.cookieClear(scope);
      },
    };
  }

  function buildCookies() {
    const cookies = cookieMethods(null);
    cookies.for = function (target) {
      if (target === undefined || target === null) {
        fail('rq.cookies.for needs a URL or a domain, such as "https://api.example.com" or "example.com".');
      }
      return Object.freeze(cookieMethods(native.cookieTarget(String(target))));
    };
    return Object.freeze(cookies);
  }

  // MARK: Tests

  const pendingTests = new Set();

  function errorMessage(error) {
    if (error instanceof Error) {
      return error.message || String(error);
    }
    return describe(error);
  }

  function test(name, callback) {
    const title = String(name);
    if (typeof callback !== 'function') {
      native.test(title, 'failed', 'rq.test needs a function to run.');
      return;
    }
    let outcome;
    try {
      outcome = callback();
    } catch (error) {
      native.test(title, 'failed', errorMessage(error));
      return;
    }
    if (outcome !== null && typeof outcome === 'object' && typeof outcome.then === 'function') {
      const entry = { title };
      pendingTests.add(entry);
      outcome.then(() => {
        if (pendingTests.delete(entry)) {
          native.test(title, 'passed', undefined);
        }
      }, (error) => {
        if (pendingTests.delete(entry)) {
          native.test(title, 'failed', errorMessage(error));
        }
      });
      return;
    }
    native.test(title, 'passed', undefined);
  }
  test.skip = function (name) {
    native.test(String(name), 'skipped', undefined);
  };

  // MARK: Stream handlers

  /// A stream script's handlers, by what they take, in the order they registered. Registering for the other kind of
  /// stream is no error, so a folder's or the project's script can serve every protocol; it just never runs.
  const handlers = { event: [], message: [] };
  let isRegistering = true;
  /// Bumped by each call, so a handler that never settled and resumes late can't run beside a later call's.
  let callGeneration = 0;

  function register(kind, name, handler, protocols) {
    if (!isStream) {
      fail(`rq.${name} works only in stream scripts.`);
    }
    if (typeof handler !== 'function') {
      fail(`rq.${name} needs a function to run on each ${kind}.`);
    }
    if (!isRegistering) {
      fail(`rq.${name} registers a handler only while a stream script's top level runs, not from a handler or later.`);
    }
    if (protocols.includes(info.protocol)) {
      handlers[kind].push(handler);
    }
  }

  /// Text as it is, `ArrayBuffer`s and typed arrays as WebSocket binary, and anything else as JSON text.
  function send(message) {
    if (!isStream) {
      fail('rq.send works only in stream scripts.');
    }
    if (info.protocol === 'http') {
      fail('rq.send can\'t reply on an event stream, which only receives.');
    }
    if (message instanceof ArrayBuffer || ArrayBuffer.isView(message)) {
      if (info.protocol === 'grpc') {
        fail('rq.send sends a gRPC message as JSON: an object, or its text.');
      }
      const view = message instanceof ArrayBuffer ? new Uint8Array(message) : new Uint8Array(message.buffer, message.byteOffset, message.byteLength);
      // A copy of exactly its bytes, as a view may cover only part of its buffer.
      native.sendBinary(view.slice().buffer);
      return;
    }
    if (typeof message === 'string') {
      if (info.protocol === 'grpc') {
        parseJSON(message, 'The message');
      }
      native.send(message);
      return;
    }
    const text = message === undefined ? undefined : JSON.stringify(message);
    if (text === undefined) {
      fail(`rq.send needs text or a value JSON can hold, not ${describe(message)}.`);
    }
    native.send(text);
  }

  function handlerArgument(item) {
    switch (item.shape) {
      case 'event':
        return eventObject(item);
      case 'socket':
        return socketMessageObject(item);
      default:
        return grpcMessageObject(item.json);
    }
  }

  // MARK: rq

  let request;
  let response;
  const rq = {
    info: Object.freeze({
      phase,
      level: info.level,
      levelName: info.levelName,
      requestName: info.requestName,
      requestId: info.requestId,
      protocol: info.protocol,
      environment: info.environment,
      iteration: info.iteration,
      iterationCount: info.iterationCount,
    }),
    iterationData: Object.freeze({
      get: (key) => native.dataGet(String(key)),
      has: (key) => native.dataGet(String(key)) !== undefined,
      toObject: () => native.dataValues(),
    }),
    execution: Object.freeze({
      skipRequest() {
        if (!isPre) {
          fail('rq.execution.skipRequest() works only in pre-request scripts.');
        }
        native.skipRequest();
      },
      setNextRequest(request) {
        if (request === undefined) {
          fail('rq.execution.setNextRequest needs a request\'s name or ID, or null to end the iteration.');
        }
        native.setNextRequest(request === null ? null : String(request));
      },
    }),
    environment: Object.freeze(variableScope('environment', info.environment)),
    defaultEnvironment: Object.freeze(variableScope('defaultEnvironment', info.defaultEnvironment)),
    globals: Object.freeze(variableScope('global', 'Global')),
    variables: Object.freeze(variables),
    cookies: buildCookies(),
    onEvent: (handler) => register('event', 'onEvent', handler, ['http']),
    onMessage: (handler) => register('message', 'onMessage', handler, ['grpc', 'websocket']),
    send,
    test,
    crypto: cryptoHelpers,
  };
  Object.defineProperty(rq, 'request', {
    get: () => (request === undefined ? (request = buildRequest()) : request),
    enumerable: true,
  });
  Object.defineProperty(rq, 'response', {
    get() {
      if (isPre) {
        fail('rq.response is only available in stream and post-response scripts.');
      }
      return response === undefined ? (response = buildResponse()) : response;
    },
    enumerable: true,
  });
  Object.defineProperty(globalThis, 'rq', { value: rq, enumerable: false });

  // What the runner's wrapper and drain loop call; `expect.js` adds `expect` to `rq` before it's frozen.
  Object.defineProperty(globalThis, '__rq', {
    value: {
      runLevel(body) {
        body().then(() => native.settled(undefined), (error) => native.settled(error instanceof Error ? error : new Error(errorMessage(error))));
      },
      /// Awaits each of `kind`'s handlers with `item` in turn, reporting the first failure of each, then settles
      /// the call.
      runCall(kind, item) {
        const generation = ++callGeneration;
        const argument = handlerArgument(item);
        const list = handlers[kind].slice();
        (async () => {
          for (const handler of list) {
            if (generation !== callGeneration) {
              return;
            }
            try {
              await handler(argument);
            } catch (error) {
              if (generation === callGeneration) {
                native.handlerFailed(error instanceof Error ? error : new Error(errorMessage(error)));
              }
            }
          }
          if (generation === callGeneration) {
            native.settled(undefined);
          }
        })();
      },
      closeRegistration() {
        isRegistering = false;
      },
      handlerCount: (kind) => handlers[kind].length,
      pendingTestCount: () => pendingTests.size,
      abandonPendingTests() {
        for (const entry of pendingTests) {
          native.test(entry.title, 'failed', 'The test didn\'t finish before its script ended.');
        }
        pendingTests.clear();
      },
      describe,
      fail,
      variableText,
    },
    enumerable: false,
  });
})(globalThis.__native);
