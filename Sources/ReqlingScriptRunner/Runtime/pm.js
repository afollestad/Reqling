// `pm`: the common subset of Postman's script API over `rq`, so scripts written for Postman run unchanged. What
// Reqling doesn't support throws a clear error naming it, never a silent no-op. Evaluated last: it seals `rq`.
'use strict';
(function (internals) {
  const rq = globalThis.rq;
  const { fail } = internals;

  function unsupported(name, reason) {
    return () => fail(`${name} isn't supported in Reqling scripts${reason ? `: ${reason}` : ''}.`);
  }

  function variableScope(scope, extras) {
    return Object.freeze(Object.assign({
      get: (key) => scope.get(key),
      set: (key, value) => scope.set(key, value),
      unset: (key) => scope.unset(key),
      has: (key) => scope.has(key),
      toObject: () => scope.toObject(),
      clear: unsupported('clear()', 'unset each key instead'),
    }, extras || {}));
  }

  /// Postman's header and query lists take `{ key, value }` objects, or a key and value.
  function postmanList(list) {
    const entry = (item, value) => (item !== null && typeof item === 'object' ? [item.key, item.value] : [item, value]);
    const mutable = typeof list.upsert === 'function';
    const object = {
      get: (name) => list.get(name),
      has: (name) => list.has(name),
      all: () => list.all().map(({ name, value }) => ({ key: name, value })),
      toObject: () => list.toObject(),
      add(item, value) {
        if (!mutable) {
          fail('Only pre-request scripts can change the request.');
        }
        const [name, text] = entry(item, value);
        list.add(name, text);
      },
      upsert(item, value) {
        if (!mutable) {
          fail('Only pre-request scripts can change the request.');
        }
        const [name, text] = entry(item, value);
        list.upsert(name, text);
      },
      remove(item) {
        if (!mutable) {
          fail('Only pre-request scripts can change the request.');
        }
        list.remove(item !== null && typeof item === 'object' ? item.key : item);
      },
    };
    return Object.freeze(object);
  }

  function buildRequest() {
    const request = rq.request;
    const query = request.query ? postmanList(request.query) : undefined;
    return Object.freeze({
      method: request.method,
      headers: postmanList(request.headers),
      url: Object.freeze({
        query,
        toString() {
          const pairs = request.query ? request.query.all() : [];
          return pairs.length === 0 ? request.url : `${request.url}?${pairs.map(({ name, value }) => `${name}=${value}`).join('&')}`;
        },
      }),
      body: request.body ? Object.freeze({ mode: request.body.mode, raw: request.body.raw }) : undefined,
    });
  }

  function httpResponse() {
    const response = rq.response;
    if (response.text === undefined || response.events !== undefined) {
      fail('pm.response describes an HTTP response; read rq.response for this one');
    }
    return response;
  }

  function responseAssertions(negate) {
    const check = (passed, positive, negative) => {
      if (passed === negate) {
        throw new Error(negate ? negative : positive);
      }
    };
    const have = Object.freeze({
      status(expected) {
        const response = httpResponse();
        const passed = typeof expected === 'number' ? response.code === expected : response.status === String(expected);
        check(passed, `expected response to have status ${expected} but got ${response.code}`, `expected response to not have status ${expected}`);
      },
      header(name, value) {
        const actual = httpResponse().headers.get(name);
        const passed = actual !== undefined && (value === undefined || actual === String(value));
        check(passed, `expected response to have header ${name}${value === undefined ? '' : `: ${value}`}`, `expected response to not have header ${name}`);
      },
      body(expected) {
        const text = httpResponse().text();
        const passed = expected === undefined ? text.length > 0
          : expected instanceof RegExp ? expected.test(text) : text === String(expected);
        check(passed, 'expected the response body to match', 'expected the response body to not match');
      },
      jsonBody(path, value) {
        let json;
        try {
          json = httpResponse().json();
        } catch (error) {
          check(false, 'expected the response body to be JSON', 'expected the response body to not be JSON');
          return;
        }
        if (path === undefined) {
          check(true, '', 'expected the response body to not be JSON');
          return;
        }
        const found = String(path).split('.').reduce(
          (current, key) => (current !== null && current !== undefined ? current[key] : undefined),
          json
        );
        const passed = arguments.length < 2 ? found !== undefined : JSON.stringify(found) === JSON.stringify(value);
        check(passed, `expected the response body to have ${path}${arguments.length < 2 ? '' : ` of ${JSON.stringify(value)}`}`, `expected the response body to not have ${path}`);
      },
    });
    const be = Object.freeze({
      get ok() {
        const code = httpResponse().code;
        check(code >= 200 && code < 300, `expected a 2xx response but got ${code}`, `expected a response other than 2xx but got ${code}`);
        return undefined;
      },
      get success() {
        return be.ok;
      },
      get json() {
        let isJSON = true;
        try {
          httpResponse().json();
        } catch (error) {
          isJSON = false;
        }
        check(isJSON, 'expected the response body to be JSON', 'expected the response body to not be JSON');
        return undefined;
      },
    });
    return { have, be };
  }

  function buildResponse() {
    const response = httpResponse();
    const positive = responseAssertions(false);
    const negative = responseAssertions(true);
    return Object.freeze({
      code: response.code,
      status: response.status,
      responseTime: response.responseTime,
      headers: postmanList(response.headers),
      size: () => response.size,
      text: () => response.text(),
      json: () => response.json(),
      to: Object.freeze({ have: positive.have, be: positive.be, not: Object.freeze({ have: negative.have, be: negative.be }) }),
    });
  }

  /// Postman's jar calls back with `(error, result)`; here, before the call returns. A callback that throws is never
  /// called a second time with its own error, and a failure without a callback throws.
  function settle(callback, body) {
    let result;
    try {
      result = body();
    } catch (error) {
      if (typeof callback !== 'function') {
        throw error;
      }
      callback(error);
      return;
    }
    if (typeof callback === 'function') {
      callback(null, result);
    }
  }

  const postmanCookieKeys = ['name', 'value', 'domain', 'path', 'expires', 'maxAge', 'secure', 'httpOnly', 'sameSite'];

  /// Postman's `{ name, value, ...options }` as `rq.cookies`' name, value, and options; `maxAge`, in seconds, wins over
  /// `expires`, as it does in a `Set-Cookie`.
  function cookieFromObject(cookie) {
    const options = {};
    for (const key of Object.keys(cookie)) {
      if (!postmanCookieKeys.includes(key)) {
        fail(`pm.cookies.jar().set takes ${postmanCookieKeys.join(', ')}, not "${key}".`);
      }
      if (!['name', 'value', 'maxAge'].includes(key)) {
        options[key] = cookie[key];
      }
    }
    if (cookie.maxAge !== undefined && cookie.maxAge !== null) {
      options.expires = Date.now() + Number(cookie.maxAge) * 1000;
    }
    return [cookie.name, cookie.value, options];
  }

  function setCookie(url, name, value, options) {
    const scope = rq.cookies.for(url);
    scope.set(name, value, options);
    return scope.all().find((cookie) => cookie.name === String(name));
  }

  const cookieJar = Object.freeze({
    get: (url, name, callback) => settle(callback, () => rq.cookies.for(url).get(name)),
    getAll: (url, callback) => settle(callback, () => rq.cookies.for(url).all()),
    set(url, name, value, callback) {
      if (name !== null && typeof name === 'object') {
        return settle(value, () => setCookie(url, ...cookieFromObject(name)));
      }
      return settle(callback, () => setCookie(url, name, value));
    },
    unset: (url, name, callback) => settle(callback, () => rq.cookies.for(url).remove(name)),
    clear: (url, callback) => settle(callback, () => rq.cookies.for(url).clear()),
  });

  let request;
  let response;
  const test = (name, callback) => rq.test(name, callback);
  test.skip = (name) => rq.test.skip(name);

  const pm = {
    test,
    expect: rq.expect,
    info: Object.freeze({
      eventName: { preRequest: 'prerequest', stream: 'stream' }[rq.info.phase] || 'test',
      requestName: rq.info.requestName,
      requestId: rq.info.requestId,
      iteration: rq.info.iteration,
      iterationCount: rq.info.iterationCount,
    }),
    environment: variableScope(rq.environment, { name: rq.environment.name }),
    globals: variableScope(rq.globals),
    collectionVariables: variableScope(rq.defaultEnvironment),
    variables: variableScope(rq.variables, { replaceIn: (text) => rq.variables.replaceIn(text) }),
    sendRequest: unsupported('pm.sendRequest', 'scripts can\'t make network calls'),
    cookies: Object.freeze({
      get: (name) => rq.cookies.get(name),
      has: (name) => rq.cookies.has(name),
      toObject: () => rq.cookies.toObject(),
      jar: () => cookieJar,
    }),
    vault: Object.freeze({ get: unsupported('pm.vault'), set: unsupported('pm.vault'), unset: unsupported('pm.vault') }),
    iterationData: Object.freeze({
      get: (key) => rq.iterationData.get(key),
      has: (key) => rq.iterationData.has(key),
      toObject: () => rq.iterationData.toObject(),
    }),
    execution: Object.freeze({
      setNextRequest: (request) => rq.execution.setNextRequest(request),
      skipRequest: () => rq.execution.skipRequest(),
    }),
    visualizer: Object.freeze({ set: unsupported('pm.visualizer') }),
  };
  Object.defineProperty(pm, 'request', { get: () => (request === undefined ? (request = buildRequest()) : request), enumerable: true });
  Object.defineProperty(pm, 'response', { get: () => (response === undefined ? (response = buildResponse()) : response), enumerable: true });
  Object.defineProperty(globalThis, 'pm', { value: Object.freeze(pm), enumerable: false });
  Object.freeze(rq);
})(globalThis.__rq);
