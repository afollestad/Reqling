// `rq.expect`: the common subset of Chai's BDD assertions, so scripts written for Postman's `pm.expect` read the same.
// An assertion this subset lacks throws a clear "not supported" error rather than passing silently.
'use strict';
(function (internals) {
  const { describe, fail } = internals;

  const chainWords = new Set([
    'to', 'be', 'been', 'is', 'that', 'which', 'and', 'has', 'have', 'with', 'at', 'of', 'same', 'but', 'does', 'still', 'also',
  ]);
  const methodAssertions = new Set([
    'equal', 'equals', 'eq', 'eql', 'eqls', 'include', 'includes', 'contain', 'contains', 'property', 'a', 'an',
    'above', 'gt', 'greaterThan', 'below', 'lt', 'lessThan', 'least', 'gte', 'most', 'lte', 'within', 'match', 'matches',
    'lengthOf', 'length', 'oneOf', 'keys', 'key', 'members', 'instanceOf', 'instanceof', 'string', 'satisfy', 'satisfies',
    'closeTo', 'approximately', 'throw', 'throws',
  ]);
  /// What a Proxy must let through untouched, so awaiting, logging, or serializing an assertion never throws.
  const passThrough = new Set(['then', 'toJSON', 'constructor', 'inspect', 'valueOf', 'toString', 'nodeType', 'asymmetricMatch']);

  function deepEqual(left, right, seen) {
    if (Object.is(left, right)) {
      return true;
    }
    if (typeof left !== 'object' || typeof right !== 'object' || left === null || right === null) {
      return false;
    }
    const pairs = seen || [];
    if (pairs.some(([a, b]) => a === left && b === right)) {
      return true;
    }
    pairs.push([left, right]);
    if (Array.isArray(left) !== Array.isArray(right) || Object.getPrototypeOf(left) !== Object.getPrototypeOf(right)) {
      return false;
    }
    if (left instanceof Date) {
      return left.getTime() === right.getTime();
    }
    const leftKeys = Object.keys(left);
    const rightKeys = Object.keys(right);
    return leftKeys.length === rightKeys.length
      && leftKeys.every((key) => Object.prototype.hasOwnProperty.call(right, key) && deepEqual(left[key], right[key], pairs));
  }

  function typeName(value) {
    if (value === null) {
      return 'null';
    }
    if (Array.isArray(value)) {
      return 'array';
    }
    if (value instanceof RegExp) {
      return 'regexp';
    }
    if (value instanceof Date) {
      return 'date';
    }
    return typeof value;
  }

  function show(value) {
    if (typeof value === 'string') {
      return JSON.stringify(value);
    }
    const text = describe(value);
    return text.length > 200 ? `${text.slice(0, 200)}…` : text;
  }

  function sizeOf(value) {
    if (typeof value === 'string' || Array.isArray(value)) {
      return value.length;
    }
    if (value instanceof Map || value instanceof Set) {
      return value.size;
    }
    if (value !== null && typeof value === 'object') {
      return Object.keys(value).length;
    }
    return fail(`expected ${show(value)} to have a length or size`);
  }

  function includes(container, item, deep) {
    if (typeof container === 'string') {
      return container.includes(String(item));
    }
    if (Array.isArray(container)) {
      return container.some((element) => (deep ? deepEqual(element, item) : element === item));
    }
    if (container instanceof Set || container instanceof Map) {
      return container.has(item);
    }
    if (container !== null && typeof container === 'object' && item !== null && typeof item === 'object') {
      return Object.keys(item).every((key) => (deep ? deepEqual(container[key], item[key]) : container[key] === item[key]));
    }
    return fail(`expected ${show(container)} to be a string, array, or object to look inside`);
  }

  function expect(actual, label) {
    const state = { actual, negate: false, deep: false, own: false, label: label === undefined ? '' : `${label}: ` };
    let proxy;

    function check(passed, positive, negative) {
      if (passed === state.negate) {
        throw new Error(state.label + (state.negate ? negative : positive));
      }
      return proxy;
    }

    const methods = {
      equal(expected) {
        const passed = state.deep ? deepEqual(state.actual, expected) : state.actual === expected;
        const word = state.deep ? 'deeply equal' : 'equal';
        return check(passed, `expected ${show(state.actual)} to ${word} ${show(expected)}`, `expected ${show(state.actual)} to not ${word} ${show(expected)}`);
      },
      eql(expected) {
        return check(deepEqual(state.actual, expected), `expected ${show(state.actual)} to deeply equal ${show(expected)}`, `expected ${show(state.actual)} to not deeply equal ${show(expected)}`);
      },
      include(item) {
        return check(includes(state.actual, item, state.deep), `expected ${show(state.actual)} to include ${show(item)}`, `expected ${show(state.actual)} to not include ${show(item)}`);
      },
      property(name, ...expected) {
        const target = state.actual;
        const has = target !== null && target !== undefined
          && (state.own ? Object.prototype.hasOwnProperty.call(target, name) : name in Object(target));
        if (expected.length === 0) {
          check(has, `expected ${show(target)} to have property ${show(name)}`, `expected ${show(target)} to not have property ${show(name)}`);
          if (has) {
            state.actual = target[name];
          }
          return proxy;
        }
        const value = has ? target[name] : undefined;
        const matches = has && (state.deep ? deepEqual(value, expected[0]) : value === expected[0]);
        return check(matches, `expected ${show(target)} to have property ${show(name)} of ${show(expected[0])}, but got ${show(value)}`, `expected ${show(target)} to not have property ${show(name)} of ${show(expected[0])}`);
      },
      a(type) {
        const wanted = String(type).toLowerCase();
        return check(typeName(state.actual) === wanted, `expected ${show(state.actual)} to be a ${wanted}`, `expected ${show(state.actual)} to not be a ${wanted}`);
      },
      above(bound) {
        return check(state.actual > bound, `expected ${show(state.actual)} to be above ${show(bound)}`, `expected ${show(state.actual)} to be at most ${show(bound)}`);
      },
      below(bound) {
        return check(state.actual < bound, `expected ${show(state.actual)} to be below ${show(bound)}`, `expected ${show(state.actual)} to be at least ${show(bound)}`);
      },
      least(bound) {
        return check(state.actual >= bound, `expected ${show(state.actual)} to be at least ${show(bound)}`, `expected ${show(state.actual)} to be below ${show(bound)}`);
      },
      most(bound) {
        return check(state.actual <= bound, `expected ${show(state.actual)} to be at most ${show(bound)}`, `expected ${show(state.actual)} to be above ${show(bound)}`);
      },
      within(low, high) {
        return check(state.actual >= low && state.actual <= high, `expected ${show(state.actual)} to be within ${show(low)}..${show(high)}`, `expected ${show(state.actual)} to not be within ${show(low)}..${show(high)}`);
      },
      closeTo(expected, delta) {
        return check(Math.abs(state.actual - expected) <= delta, `expected ${show(state.actual)} to be within ${show(delta)} of ${show(expected)}`, `expected ${show(state.actual)} to not be within ${show(delta)} of ${show(expected)}`);
      },
      match(pattern) {
        const regex = pattern instanceof RegExp ? pattern : new RegExp(pattern);
        return check(regex.test(String(state.actual)), `expected ${show(state.actual)} to match ${regex}`, `expected ${show(state.actual)} to not match ${regex}`);
      },
      string(part) {
        return check(String(state.actual).includes(part), `expected ${show(state.actual)} to contain ${show(part)}`, `expected ${show(state.actual)} to not contain ${show(part)}`);
      },
      lengthOf(count) {
        const size = sizeOf(state.actual);
        return check(size === count, `expected ${show(state.actual)} to have a length of ${count} but got ${size}`, `expected ${show(state.actual)} to not have a length of ${count}`);
      },
      oneOf(list) {
        const passed = list.some((item) => (state.deep ? deepEqual(item, state.actual) : item === state.actual));
        return check(passed, `expected ${show(state.actual)} to be one of ${show(list)}`, `expected ${show(state.actual)} to not be one of ${show(list)}`);
      },
      keys(...names) {
        const wanted = names.length === 1 && Array.isArray(names[0]) ? names[0] : names;
        const actualKeys = state.actual instanceof Map ? Array.from(state.actual.keys()) : Object.keys(Object(state.actual));
        const passed = wanted.length === actualKeys.length && wanted.every((name) => actualKeys.includes(name));
        return check(passed, `expected ${show(state.actual)} to have keys ${show(wanted)}`, `expected ${show(state.actual)} to not have keys ${show(wanted)}`);
      },
      members(list) {
        const actualList = Array.from(state.actual || []);
        const passed = list.length === actualList.length && list.every((item) => includes(actualList, item, state.deep));
        return check(passed, `expected ${show(state.actual)} to have the same members as ${show(list)}`, `expected ${show(state.actual)} to not have the same members as ${show(list)}`);
      },
      instanceOf(constructor) {
        return check(state.actual instanceof constructor, `expected ${show(state.actual)} to be an instance of ${constructor && constructor.name}`, `expected ${show(state.actual)} to not be an instance of ${constructor && constructor.name}`);
      },
      satisfy(predicate) {
        return check(Boolean(predicate(state.actual)), `expected ${show(state.actual)} to satisfy ${predicate.name || 'the condition'}`, `expected ${show(state.actual)} to not satisfy ${predicate.name || 'the condition'}`);
      },
      throw(expected) {
        let thrown;
        let didThrow = false;
        try {
          state.actual();
        } catch (error) {
          didThrow = true;
          thrown = error;
        }
        let passed = didThrow;
        if (didThrow && expected !== undefined) {
          const message = thrown instanceof Error ? thrown.message : String(thrown);
          passed = expected instanceof RegExp ? expected.test(message)
            : typeof expected === 'function' ? thrown instanceof expected
              : message.includes(String(expected));
        }
        return check(passed, `expected the function to throw${expected === undefined ? '' : ` ${show(expected)}`}`, 'expected the function to not throw');
      },
    };
    const aliases = {
      equals: 'equal', eq: 'equal', eqls: 'eql', includes: 'include', contain: 'include', contains: 'include', an: 'a',
      gt: 'above', greaterThan: 'above', lt: 'below', lessThan: 'below', gte: 'least', lte: 'most', matches: 'match',
      length: 'lengthOf', key: 'keys', instanceof: 'instanceOf', satisfies: 'satisfy', approximately: 'closeTo', throws: 'throw',
    };

    const properties = {
      ok: () => check(Boolean(state.actual), `expected ${show(state.actual)} to be truthy`, `expected ${show(state.actual)} to be falsy`),
      true: () => check(state.actual === true, `expected ${show(state.actual)} to be true`, `expected ${show(state.actual)} to not be true`),
      false: () => check(state.actual === false, `expected ${show(state.actual)} to be false`, `expected ${show(state.actual)} to not be false`),
      null: () => check(state.actual === null, `expected ${show(state.actual)} to be null`, `expected ${show(state.actual)} to not be null`),
      undefined: () => check(state.actual === undefined, `expected ${show(state.actual)} to be undefined`, `expected ${show(state.actual)} to not be undefined`),
      NaN: () => check(Number.isNaN(state.actual), `expected ${show(state.actual)} to be NaN`, `expected ${show(state.actual)} to not be NaN`),
      exist: () => check(state.actual !== null && state.actual !== undefined, `expected ${show(state.actual)} to exist`, `expected ${show(state.actual)} to not exist`),
      empty: () => check(sizeOf(state.actual) === 0, `expected ${show(state.actual)} to be empty`, `expected ${show(state.actual)} to not be empty`),
    };

    proxy = new Proxy({}, {
      get(target, name) {
        if (typeof name === 'symbol' || passThrough.has(name)) {
          return undefined;
        }
        if (chainWords.has(name)) {
          return proxy;
        }
        if (name === 'not') {
          state.negate = !state.negate;
          return proxy;
        }
        if (name === 'deep' || name === 'nested') {
          state.deep = true;
          return proxy;
        }
        if (name === 'own') {
          state.own = true;
          return proxy;
        }
        if (Object.prototype.hasOwnProperty.call(properties, name)) {
          return properties[name]();
        }
        const method = methods[aliases[name] || name];
        if (method !== undefined && methodAssertions.has(name)) {
          return method;
        }
        return fail(`expect(…).${name} is not supported in Reqling scripts.`);
      },
    });
    return proxy;
  }

  globalThis.rq.expect = expect;
  internals.expect = expect;
})(globalThis.__rq);
