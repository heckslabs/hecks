// Runs the generated redirect_host function against stub CloudFront events.
//
// usage: node edge_function_cases.js <function.js> '<{"canonical":..,"aliases":[..],"paths":[..]}>'
// Prints a JSON array of { name, ok, error } and exits 0; the spec reads it.
"use strict";
const assert = require("node:assert");
const fs = require("node:fs");
const vm = require("node:vm");

const [file, configText] = process.argv.slice(2);
const config = JSON.parse(configText);
const sandbox = {};
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(file, "utf8"), sandbox, { filename: file });
const handler = sandbox.handler;

const event = (host, uri, querystring = {}, method = "GET") => ({
  request: { method, uri, querystring, headers: host === null ? {} : { host: { value: host } } }
});
const location = (response) => response.headers && response.headers.location.value;
const passes = (e) => assert.strictEqual(handler(e), e.request);

const alias = config.aliases[0];
const first = config.paths[0];
const second = config.paths[config.paths.length - 1];
const to = (path, query = "") => `https://${config.canonical}${path}${query}`;
const cases = [];
const test = (name, body) => cases.push({ name, body });

config.aliases.forEach((host) => {
  config.paths.forEach((path) => {
    test(`redirects ${host}${path}`, () => assert.strictEqual(location(handler(event(host, path))), to(path)));
  });
});
test("answers 302 Found", () => {
  const r = handler(event(alias, first));
  assert.strictEqual(r.statusCode, 302);
  assert.strictEqual(r.statusDescription, "Found");
});
test("is never cached", () => assert.strictEqual(handler(event(alias, first)).headers["cache-control"].value, "no-store"));
test("answers only location and cache-control", () => {
  assert.deepStrictEqual(Object.keys(handler(event(alias, first)).headers).sort(), ["cache-control", "location"]);
});
test("redirects HEAD", () => assert.strictEqual(handler(event(alias, first, {}, "HEAD")).statusCode, 302));
["POST", "PUT", "PATCH", "DELETE", "OPTIONS"].forEach((method) => {
  test(`passes ${method} through untouched`, () => passes(event(alias, first, {}, method)));
});
test("keeps the query intact", () => {
  const query = { a: { value: "1" }, b: { value: "x%20y" } };
  assert.strictEqual(location(handler(event(alias, second, query))), to(second, "?a=1&b=x%20y"));
});
test("keeps repeated keys in order", () => {
  const query = { k: { value: "1", multiValue: [{ value: "1" }, { value: "2" }] } };
  assert.strictEqual(location(handler(event(alias, first, query))), to(first, "?k=1&k=2"));
});
test("keeps a key with an empty value as the bare key", () => {
  assert.strictEqual(location(handler(event(alias, first, { k: { value: "" } }))), to(first, "?k"));
});
test("adds no question mark without a query", () => assert.strictEqual(location(handler(event(alias, first))), to(first)));
test("keeps an already encoded value as it is", () => {
  const query = { n: { value: "%E2%9C%93" }, s: { value: "a%26b" } };
  assert.strictEqual(location(handler(event(alias, first, query))), to(first, "?n=%E2%9C%93&s=a%26b"));
});
test("encodes a decoded value that would split the query", () => {
  const query = { x: { value: "a&b=c#d e" } };
  assert.strictEqual(location(handler(event(alias, first, query))), to(first, "?x=a%26b%3Dc%23d%20e"));
});
test("encodes a decoded line break so the header cannot be split", () => {
  const value = location(handler(event(alias, first, { x: { value: "a\r\nSet-Cookie: x=1" } })));
  assert.ok(!/[\r\n]/.test(value), value);
});
test("encodes a decoded unicode value as UTF-8", () => {
  assert.strictEqual(location(handler(event(alias, first, { x: { value: "café ✓" } }))), to(first, "?x=caf%C3%A9%20%E2%9C%93"));
});
test("encodes an astral character (a surrogate pair) as one UTF-8 sequence", () => {
  assert.strictEqual(location(handler(event(alias, first, { x: { value: "\u{1F600}" } }))), to(first, "?x=%F0%9F%98%80"));
});
test("encodes astral characters next to other text and to each other", () => {
  const value = "a\u{1F600}\u{1F4A9} b\u{10FFFF}";
  assert.strictEqual(location(handler(event(alias, first, { x: { value } }))), to(first, "?x=a%F0%9F%98%80%F0%9F%92%A9%20b%F4%8F%BF%BF"));
});
test("encodes an astral character in a key", () => {
  assert.strictEqual(location(handler(event(alias, first, { "\u{1F600}": { value: "1" } }))), to(first, "?%F0%9F%98%80=1"));
});
test("turns a lone high surrogate into U+FFFD without throwing", () => {
  assert.strictEqual(location(handler(event(alias, first, { x: { value: "a\uD800b" } }))), to(first, "?x=a%EF%BF%BDb"));
});
test("turns a lone high surrogate at the end into U+FFFD", () => {
  assert.strictEqual(location(handler(event(alias, first, { x: { value: "a\uDBFF" } }))), to(first, "?x=a%EF%BF%BD"));
});
test("turns a lone low surrogate into U+FFFD", () => {
  assert.strictEqual(location(handler(event(alias, first, { x: { value: "\uDC00a" } }))), to(first, "?x=%EF%BF%BDa"));
});
test("turns a reversed pair (low then high) into two U+FFFD", () => {
  assert.strictEqual(location(handler(event(alias, first, { x: { value: "\uDC00\uD800" } }))), to(first, "?x=%EF%BF%BD%EF%BF%BD"));
});
test("a high surrogate followed by a plain character keeps the character", () => {
  assert.strictEqual(location(handler(event(alias, first, { x: { value: "\uD800a" } }))), to(first, "?x=%EF%BF%BDa"));
});
test("keeps a valid percent escape and encodes a bare percent", () => {
  const query = { a: { value: "100%25" }, b: { value: "50%" }, c: { value: "%zz" }, d: { value: "%2541" }, e: { value: "%e" } };
  assert.strictEqual(location(handler(event(alias, first, query))), to(first, "?a=100%25&b=50%25&c=%25zz&d=%2541&e=%25e"));
});
test("keeps a plus sign as it is", () => {
  assert.strictEqual(location(handler(event(alias, first, { p: { value: "a+b" } }))), to(first, "?p=a+b"));
});
test("encodes a key as well as a value", () => {
  assert.strictEqual(location(handler(event(alias, first, { "a b": { value: "1" } }))), to(first, "?a%20b=1"));
});
test("does not change the request it is given", () => {
  const e = event(alias, first, { a: { value: "1" } });
  const before = JSON.stringify(e);
  handler(e);
  assert.strictEqual(JSON.stringify(e), before);
});
test("redirects an alias in any casing", () => {
  assert.strictEqual(handler(event(alias.toUpperCase(), first)).statusCode, 302);
});
test("redirects an alias that carries a port", () => assert.strictEqual(handler(event(`${alias}:443`, first)).statusCode, 302));
test("passes the canonical host through (no loop)", () => passes(event(config.canonical, first)));
test("passes the canonical host in any casing through", () => passes(event(config.canonical.toUpperCase(), first)));
test("passes the canonical host with a port through", () => passes(event(`${config.canonical}:443`, first)));
test("passes an unknown host through", () => passes(event("other.example.invalid", first)));
test("passes a request with no host header through", () => passes(event(null, first)));
test("passes an empty host through", () => passes(event("", first)));
[`${first}/`, `${first}/x`, first.toUpperCase(), "/", "/logout", "/auth", "/auth/", "/auth/other", "/auth/start/callback",
 "/about.html", `${first}?x=1`].filter((path) => !config.paths.includes(path)).forEach((path) => {
  test(`passes ${path} through`, () => passes(event(alias, path)));
});

const results = cases.map(({ name, body }) => {
  try { body(); return { name, ok: true }; } catch (error) { return { name, ok: false, error: String(error.message).slice(0, 300) }; }
});
process.stdout.write(JSON.stringify(results));
