"use strict";
// Loads wiring.html's page script with a fake DOM, then runs a scenario and prints its result as JSON.
const fs = require("node:fs");
const vm = require("node:vm");
const [page, scenario] = process.argv.slice(2);
const html = fs.readFileSync(page, "utf8");
const code = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1];

function fake() {
  const el = { value: "", classList: new Set(), children: [], dataset: {}, style: {}, textContent: "", namespaceURI: "svg",
    add(...c) { c.forEach((x) => this.classList.add(x)); }, };
  const list = { add: (...c) => c.forEach((x) => el.classList.add(x)), remove: (...c) => c.forEach((x) => el.classList.delete(x)),
    toggle: (c, on) => { (on === undefined ? !el.classList.has(c) : on) ? el.classList.add(c) : el.classList.delete(c); },
    contains: (c) => el.classList.has(c) };
  return new Proxy(el, { get(t, k) {
    if (k === "classList") return list;
    if (k === "text") return t.textContent;
    if (k in t) return t[k];
    if (k === "getBoundingClientRect") return () => ({ width: 800, height: 600, left: 0, top: 0 });
    if (k === "getTotalLength") return () => 100;
    if (k === "getPointAtLength") return () => ({ x: 0, y: 0 });
    if (k === "querySelector" || k === "closest") return () => fake();
    if (k === "querySelectorAll") return () => [];
    if (k === "setAttribute") return (n, v) => { t["@" + n] = v; };
    if (k === "append" || k === "replaceChildren") return (...kids) => { t.children = kids; t.textContent = kids.map((x) => (x && x.textContent !== undefined ? x.textContent : String(x))).join(" "); };
    return () => {};
  }, set(t, k, v) { t[k] = v; return true; } });
}
const els = new Map();
const sandbox = { console, performance, setTimeout, clearTimeout, setInterval: () => 0, requestAnimationFrame: () => 0,
  matchMedia: () => ({ matches: false }), addEventListener() {}, location: { hash: "", pathname: "/" }, history: { replaceState() {} },
  localStorage: { getItem: () => null, setItem() {} }, fetch: () => new Promise(() => {}), boardStream: undefined,
  document: { addEventListener() {}, getElementById: (id) => els.get(id) || els.set(id, fake()).get(id), createElement: fake, createElementNS: fake } };
sandbox.window = sandbox; sandbox.una = () => fake();
vm.createContext(sandbox);
const text = (id) => sandbox.document.getElementById(id).textContent;
sandbox.lastText = () => text("last");
vm.runInContext(code, sandbox);
const result = vm.runInContext(fs.readFileSync(scenario, "utf8"), sandbox);
console.log(JSON.stringify(result));
