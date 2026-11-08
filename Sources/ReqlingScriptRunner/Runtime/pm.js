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

  /// Assertions about `response`: `pm.response`'s, or a response `pm.sendRequest` got.
  function responseAssertions(response, negate) {
    const check = (passed, positive, negative) => {
      if (passed === negate) {
        throw new Error(negate ? negative : positive);
      }
    };
    const have = Object.freeze({
      status(expected) {
        const passed = typeof expected === 'number' ? response.code === expected : response.status === String(expected);
        check(passed, `expected response to have status ${expected} but got ${response.code}`, `expected response to not have status ${expected}`);
      },
      header(name, value) {
        const actual = response.headers.get(name);
        const passed = actual !== undefined && (value === undefined || actual === String(value));
        check(passed, `expected response to have header ${name}${value === undefined ? '' : `: ${value}`}`, `expected response to not have header ${name}`);
      },
      body(expected) {
        const text = response.text();
        const passed = expected === undefined ? text.length > 0
          : expected instanceof RegExp ? expected.test(text) : text === String(expected);
        check(passed, 'expected the response body to match', 'expected the response body to not match');
      },
      jsonBody(path, value) {
        let json;
        try {
          json = response.json();
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
        const code = response.code;
        check(code >= 200 && code < 300, `expected a 2xx response but got ${code}`, `expected a response other than 2xx but got ${code}`);
        return undefined;
      },
      get success() {
        return be.ok;
      },
      get json() {
        let isJSON = true;
        try {
          response.json();
        } catch (error) {
          isJSON = false;
        }
        check(isJSON, 'expected the response body to be JSON', 'expected the response body to not be JSON');
        return undefined;
      },
    });
    return { have, be };
  }

  /// Postman's view of an HTTP response: `rq.response`, or what `rq.sendRequest` got.
  function buildResponse(response) {
    const positive = responseAssertions(response, false);
    const negative = responseAssertions(response, true);
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

  // MARK: Requests

  const postmanRequestKeys = ['url', 'method', 'header', 'body'];

  function hasHeader(rows, name) {
    return rows.some(([key]) => key.toLowerCase() === name.toLowerCase());
  }

  /// Postman's `header`: a list of `{ key, value, disabled }` or `"Name: value"` entries, `"Name: value"` lines, or an
  /// object of names and values.
  function postmanHeaders(header) {
    if (header === undefined || header === null) {
      return [];
    }
    const line = (text) => {
      const colon = text.indexOf(':');
      return colon < 0 ? fail(`pm.sendRequest can't read the header "${text}"; write it as "Name: value".`)
        : [text.slice(0, colon).trim(), text.slice(colon + 1).trim()];
    };
    if (typeof header === 'string') {
      return header.split(/\r?\n/).filter((text) => text.trim() !== '').map(line);
    }
    if (Array.isArray(header)) {
      return header.filter((item) => !(item && item.disabled)).map((item) => {
        if (typeof item === 'string') {
          return line(item);
        }
        return item !== null && typeof item === 'object' ? [String(item.key), internals.variableText(item.value)]
          : fail('pm.sendRequest\'s headers are { key, value } objects, "Name: value" text, or an object of names and values.');
      });
    }
    if (typeof header === 'object') {
      return Object.keys(header).map((key) => [key, internals.variableText(header[key])]);
    }
    return fail('pm.sendRequest\'s headers are { key, value } objects, "Name: value" text, or an object of names and values.');
  }

  /// Postman's `{ key, value, disabled }` fields, those still on.
  function postmanFields(fields, mode) {
    if (fields === undefined || fields === null) {
      return [];
    }
    if (!Array.isArray(fields)) {
      fail(`pm.sendRequest's ${mode} body is a list of { key, value } fields.`);
    }
    return fields.filter((field) => !(field && field.disabled)).map((field) => {
      if (field === null || typeof field !== 'object') {
        fail(`pm.sendRequest's ${mode} body is a list of { key, value } fields.`);
      }
      if (field.type === 'file' || field.src !== undefined) {
        fail('pm.sendRequest can\'t send files from Reqling scripts.');
      }
      return [String(field.key), internals.variableText(field.value)];
    });
  }

  function multipart(fields, rows) {
    const boundary = `----ReqlingFormBoundary${rq.crypto.randomUUID().replace(/-/g, '')}`;
    // As browsers escape a field's name in its header.
    const escape = (text) => text.replace(/"/g, '%22').replace(/\r/g, '%0D').replace(/\n/g, '%0A');
    let text = '';
    for (const [key, value] of fields) {
      text += `--${boundary}\r\nContent-Disposition: form-data; name="${escape(key)}"\r\n\r\n${value}\r\n`;
    }
    if (!hasHeader(rows, 'content-type')) {
      rows.push(['Content-Type', `multipart/form-data; boundary=${boundary}`]);
    }
    return `${text}--${boundary}--\r\n`;
  }

  /// Postman's `body`, by its `mode`, as the text `rq.sendRequest` sends, with the `Content-Type` its mode implies
  /// unless the headers name one.
  function postmanBody(body, rows) {
    if (body === undefined || body === null || body.mode === undefined || body.mode === 'none') {
      return undefined;
    }
    const type = (value) => {
      if (!hasHeader(rows, 'content-type')) {
        rows.push(['Content-Type', value]);
      }
    };
    switch (body.mode) {
      case 'raw': {
        const options = body.options && body.options.raw;
        if (options && options.language === 'json') {
          type('application/json');
        }
        return body.raw === undefined || body.raw === null ? '' : internals.variableText(body.raw);
      }
      case 'urlencoded': {
        const encode = (text) => encodeURIComponent(text).replace(/%20/g, '+');
        type('application/x-www-form-urlencoded');
        return postmanFields(body.urlencoded, 'urlencoded').map(([key, value]) => `${encode(key)}=${encode(value)}`).join('&');
      }
      case 'formdata':
        return multipart(postmanFields(body.formdata, 'formdata'), rows);
      case 'graphql': {
        const graphQL = body.graphql || {};
        let variables = graphQL.variables;
        if (typeof variables === 'string') {
          variables = variables.trim() === '' ? undefined : JSON.parse(variables);
        }
        type('application/json');
        return JSON.stringify({ query: graphQL.query === undefined ? '' : String(graphQL.query), variables });
      }
      case 'file':
        return fail('pm.sendRequest can\'t send files from Reqling scripts.');
      default:
        return fail(`pm.sendRequest has no body mode "${body.mode}"; it takes raw, urlencoded, formdata, or graphql.`);
    }
  }

  /// Postman's request, or its URL, as `rq.sendRequest` takes it. What Reqling can't send, such as its own `auth`,
  /// throws rather than going out without it.
  function postmanRequest(request) {
    if (typeof request === 'string') {
      return request;
    }
    if (request === null || typeof request !== 'object') {
      fail('pm.sendRequest needs a URL, or a request such as { url, method, header, body }.');
    }
    for (const key of Object.keys(request)) {
      if (!postmanRequestKeys.includes(key)) {
        fail(`pm.sendRequest takes a request's ${postmanRequestKeys.join(', ')} in Reqling scripts, not "${key}".`);
      }
    }
    const url = request.url !== null && typeof request.url === 'object' ? request.url.raw : request.url;
    if (typeof url !== 'string' || url === '') {
      fail('pm.sendRequest needs the request\'s url.');
    }
    const headers = postmanHeaders(request.header);
    const body = postmanBody(request.body, headers);
    return { method: request.method === undefined ? 'GET' : request.method, url, headers, body };
  }

  /// With a callback, it's called with `(error, response)` once the reply arrives, inside the runner's call, so one that
  /// throws fails the script; without one, the call returns a promise.
  function sendRequest(request, callback) {
    const fetch = postmanRequest(request);
    if (typeof callback === 'function') {
      internals.startSend(fetch, 'pm.sendRequest', (error, response) => (error === null ? callback(null, buildResponse(response)) : callback(error)));
      return undefined;
    }
    return internals.promised((settle) => internals.startSend(fetch, 'pm.sendRequest', settle)).then(buildResponse);
  }

  function runRequest(request, options) {
    return internals.promised((settle) => internals.startRun(request, options, 'pm.execution.runRequest', settle)).then(buildResponse);
  }

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
    sendRequest,
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
      runRequest,
    }),
    visualizer: Object.freeze({ set: unsupported('pm.visualizer') }),
  };
  Object.defineProperty(pm, 'request', { get: () => (request === undefined ? (request = buildRequest()) : request), enumerable: true });
  Object.defineProperty(pm, 'response', { get: () => (response === undefined ? (response = buildResponse(httpResponse())) : response), enumerable: true });
  Object.defineProperty(globalThis, 'pm', { value: Object.freeze(pm), enumerable: false });
  Object.freeze(rq);
})(globalThis.__rq);
