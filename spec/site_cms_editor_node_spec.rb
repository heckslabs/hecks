require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "hecks/tools"
require "hecks/tools/site_routes"
require_relative "support/editor_node"

# The scenarios the editor's generated TypeScript is run through under node: a host that is a fake
# `fetch` (its members list, its /dispatch protocol) and a clock the scenario moves.
EDITOR_NODE_SCENARIO = <<~JS.freeze
  import { accountToken } from "@hecks/client";
  import { createHash } from "node:crypto";
  import { mkdirSync, readdirSync, writeFileSync } from "node:fs";
  import { createApp } from "./editor/src/app.ts";
  import { diskStorage } from "./editor/src/media/storage.ts";

  const SECRET = "scenario-secret";
  let clock = 1_800_000_000_000;
  let members = [{ email: "ed@example.org", role: "Admin" }];
  let refusal = null;
  let refusalKind = "GivenNotMet";
  let sent = [];
  const article = (slug, headline) => ({
    slug: { value: slug }, headline: { value: headline }, byline: { name: "Ann", contact: "ann@example.org" },
    tags: [{ value: "news" }], sections: [], body: { blocks: [{ kind: "paragraph", spans: [{ text: "Hi <i>", marks: [{ name: "bold" }] }] }] },
    status: "draft",
  });
  const instances = { "Press::Article#first": article("first", "First piece") };

  const answer = (extra = {}) => ({ ok: true, status: 200, json: async () => ({ instances: structuredClone(instances), refusals: [], ...extra }) });
  const fetch = async (url, init) => {
    const path = new URL(url).pathname;
    if (path === "/members") return { ok: true, status: 200, json: async () => members };
    const body = JSON.parse(init.body);
    sent.push(body);
    if (body.query) {
      const prefix = `Press::${body.query.split(".")[0].split("::")[1]}#`;
      return answer({ queries: [{ query: body.query, rows: Object.entries(instances).filter(([id]) => id.startsWith(prefix)).map(([, row]) => row) }] });
    }
    if (body.read || refusal) return answer(refusal && !body.read ? { refusals: [{ verb: body.verb, kind: refusalKind, error: refusal }] } : {});
    const [, verb] = body.verb.split(".");
    if (verb === "Draft") instances[`Press::Article#${body.with.slug.value}`] = { ...body.with, status: "draft" };
    if (verb === "RegisterPicture") instances[`Press::MediaItem#${body.with.key.value}`] = { ...body.with };
    if (verb === "Publish") instances[`Press::Article#${body.to}`].status = "published";
    if (verb === "SaveDraft") instances[`Press::Article#${body.to}`].draft_body = body.with.draft_body;
    if (verb === "PublishDraft") {
      const row = instances[`Press::Article#${body.to}`];
      if (!row.draft_body) return answer({ refusals: [{ verb: body.verb, kind: "GivenNotMet", error: "PublishDraft refused \u2014 an edit is saved" }] });
      row.body = row.draft_body;
      delete row.draft_body;
    }
    return answer();
  };

  // What `npm run build` writes; the pages link it only when it is there.
  mkdirSync(`${import.meta.dirname}/editor/dist`, { recursive: true });
  writeFileSync(`${import.meta.dirname}/editor/dist/editor.css`, "body { margin: 0; }\\n");
  writeFileSync(`${import.meta.dirname}/editor/dist/editor.js`, "export {};\\n");

  const stored = `${import.meta.dirname}/stored`;
  const app = createApp({ fetch, secret: SECRET, url: "http://host.test", now: () => clock, storage: diskStorage(stored) });
  const token = (email) => accountToken(SECRET, email, 60, { now: () => clock });
  const form = { "Content-Type": "application/x-www-form-urlencoded", Origin: "http://site.test" };
  const call = (path, init = {}) => app(new Request(`http://site.test${path}`, init));
  const signIn = async (email) => (await call(`/editor/api/sso?token=${token(email)}`)).headers.get("set-cookie")?.split(";")[0];
  const as = (cookie) => (path, init = {}) => call(path, { ...init, headers: { cookie, ...(init.headers ?? {}) } });
  const post = (path, body) => ({ method: "POST", body, headers: form });
  const last = () => sent.at(-1);
  const out = {};

  out.signInRedirect = await call(`/editor/api/sso?token=${token("ed@example.org")}`).then((r) => [r.status, r.headers.get("location")]);
  out.anonymousGet = await call("/editor/Article").then((r) => [r.status, r.headers.get("location")]);
  out.anonymousPost = await call("/editor/Article/id/first/Publish", post("", "")).then((r) => r.status);
  out.forgedCookie = await as("press_editor=forged")("/editor").then((r) => [r.status, r.headers.get("location")]);
  out.notAnEditor = await call(`/editor/api/sso?token=${token("stranger@example.org")}`).then((r) => r.status);
  out.badToken = await call("/editor/api/sso?token=nonsense").then((r) => r.status);

  const cookie = await signIn("ed@example.org");
  const editor = as(cookie);
  out.cookie = cookie.split("=")[0];
  out.home = await editor("/editor").then((r) => r.text());

  sent = [];
  const list = await editor("/editor/Article?query=Published");
  out.list = { status: list.status, html: await list.text(), sent: sent.filter((b) => b.query) };
  const detailPage = await editor("/editor/Article/id/first");
  out.detailHeaders = Object.fromEntries(["content-security-policy", "cache-control", "content-type"].map((name) => [name, detailPage.headers.get(name)]));
  out.detail = await detailPage.text();
  out.revisePage = await editor("/editor/Article/id/first/Revise").then((r) => r.text());
  out.confirmPage = await editor("/editor/Article/id/first/DiscardDraft").then((r) => r.text());
  out.missing = await editor("/editor/Article/id/none").then((r) => r.status);
  out.newForm = await editor("/editor/Article/new/Draft").then((r) => r.text());
  out.mastheadList = await editor("/editor/Masthead").then((r) => r.text());
  out.emptyList = await editor("/editor/Article?query=ByHeadline").then((r) => r.text());

  members.push({ email: "<i>@example.org", role: "Owner" });
  out.escapedPerson = await as(await signIn("<i>@example.org"))("/editor").then((r) => r.text());

  sent = [];
  const publish = await editor("/editor/Article/id/first/Publish", post("", ""));
  const noticeCookie = publish.headers.get("set-cookie")?.split(";")[0];
  out.publish = { status: publish.status, location: publish.headers.get("location"), sent: sent.filter((b) => b.verb), setCookie: publish.headers.get("set-cookie") };

  // The notice the redirect carried: shown once, cleared in the same response, refused when forged,
  // expired, or made of markup (its words are escaped).
  const withNotice = (value) => as(`${cookie}; ${value}`);
  const noticePage = await withNotice(noticeCookie)("/editor/Article/id/first");
  out.notice = { html: await noticePage.text(), setCookie: noticePage.headers.get("set-cookie") };
  out.noticeGone = await editor("/editor/Article/id/first").then((r) => r.text());
  const signature = noticeCookie.split("=")[1].split(".")[1];
  const tamperedMessage = Buffer.from(JSON.stringify({ k: "success", m: "Forged.", t: Math.floor(clock / 1000) })).toString("base64url");
  out.noticeForged = await withNotice(`press_editor_flash=${tamperedMessage}.${signature}`)("/editor/Article/id/first").then((r) => r.text());
  clock += 61_000;
  out.noticeExpired = await withNotice(noticeCookie)("/editor/Article/id/first").then((r) => r.text());
  const { flashCookie } = await import("./editor/src/flash.ts");
  out.noticeEscaped = await withNotice(flashCookie({ kind: "info", message: "<img src=x onerror=alert(1)>" }, SECRET, () => clock).split(";")[0])("/editor/Article/id/first").then((r) => r.text());

  const draft = [
    "slug.value=second", "headline.value=Second+piece", "standfirst.value=", "byline.name=Bo", "byline.contact=bo%40example.org",
    "tags.0.value=a", "tags.1.value=", "sections.0.heading=Links", "sections.0.links.0.label=Home", "sections.0.links.0.url=%2F",
    "sections.0.links.1.label=", "sections.0.links.1.url=", "sections.1.heading=", "body.blocks.0.kind=paragraph",
    "body.blocks.0.indent=1", "body.blocks.0.spans.0.text=Hello", "body.blocks.0.spans.0.marks.0.name=bold",
  ].join("&");
  sent = [];
  const created = await editor("/editor/Article/new/Draft", post("", draft));
  out.create = { status: created.status, location: created.headers.get("location"), sent: sent.filter((b) => b.verb) };

  refusal = "Revise refused: an article has a headline";
  const refused = await editor("/editor/Article/id/first/Revise", post("", "headline.value=&byline.name=Ann&byline.contact=x"));
  out.refused = { status: refused.status, html: await refused.text() };
  refusal = null;

  out.draftForms = await editor("/editor/Article/id/first/PublishDraft").then((r) => r.text());
  out.draftReviseForm = await editor("/editor/Article/id/first/SaveDraft").then((r) => r.text());
  out.draftDetail = await editor("/editor/Article/id/first").then((r) => r.text());
  sent = [];
  const noDraft = await editor("/editor/Article/id/first/PublishDraft", post("", ""));
  out.publishNoDraft = { status: noDraft.status, html: await noDraft.text() };
  out.saved = await editor("/editor/Article/id/first/SaveDraft", post("", "draft_body.blocks.0.kind=paragraph&draft_body.blocks.0.spans.0.text=Edited"))
    .then((r) => [r.status, r.headers.get("location")]);
  out.afterSave = await editor("/editor/Article/id/first/SaveDraft").then((r) => r.text());
  sent = [];
  const promoted = await editor("/editor/Article/id/first/PublishDraft", post("", ""));
  out.promoted = { status: promoted.status, location: promoted.headers.get("location"), sent: sent.filter((b) => b.verb) };
  out.afterPromote = await editor("/editor/Article/id/first/Revise").then((r) => r.text());
  out.afterPromoteDetail = await editor("/editor/Article/id/first").then((r) => r.text());

  refusal = 'Headline invariant violated \u2014 an article has a headline (given {"value":""})';
  refusalKind = "InvariantViolation";
  const invalid = await editor("/editor/Article/id/first/Revise", post("", "headline.value=&byline.name=Ann&byline.contact=x"));
  out.invariant = { status: invalid.status, html: await invalid.text() };
  refusal = null;
  refusalKind = "GivenNotMet";

  const loggedOut = await editor("/editor/logout", post("", ""));
  out.logout = { status: loggedOut.status, location: loggedOut.headers.get("location"), cookie: loggedOut.headers.get("set-cookie") };
  out.logoutCrossSite = await editor("/editor/logout", { method: "POST", body: "", headers: { ...form, Origin: "http://evil.test" } }).then((r) => r.status);
  out.signOutButton = out.home.includes('action="/editor/logout"');

  // Static files: the theme script from src/ui, the stylesheet and script from dist. Each has an ETag; the
  // page names the version, and a request that names it may be kept for good.
  const version = (file) => out.home.split(`/editor/assets/${file}?v=`)[1]?.slice(0, 12);
  const sheet = await editor(`/editor/assets/editor.css?v=${version("editor.css")}`);
  const plainSheet = await editor("/editor/assets/editor.css");
  const etag = plainSheet.headers.get("etag");
  const revalidated = await editor("/editor/assets/editor.css", { headers: { "If-None-Match": etag } });
  out.asset = {
    status: sheet.status, type: sheet.headers.get("content-type"), etag, versioned: sheet.headers.get("cache-control"),
    plain: plainSheet.headers.get("cache-control"), notModified: [revalidated.status, (await revalidated.text()).length],
    versionIsEtag: `"${version("editor.css")}"` === etag, nosniff: sheet.headers.get("x-content-type-options"),
    theme: await editor("/editor/assets/theme.js").then(async (r) => [r.status, r.headers.get("content-type"), (await r.text()).slice(0, 2)]),
  };
  out.assetLinks = {
    sheet: out.home.includes(`<link rel="stylesheet" href="/editor/assets/editor.css?v=${version("editor.css")}">`),
    script: out.home.includes(`<script type="module" src="/editor/assets/editor.js?v=${version("editor.js")}"></script>`),
    head: out.home.includes(`<script src="/editor/assets/theme.js?v=${version("theme.js")}"></script>`),
  };
  out.assetAnonymous = await call("/editor/assets/editor.css").then((r) => r.status);
  out.assetUnknown = await Promise.all(["app.ts", "..%2Fsrc%2Fapp.ts", "editor.css.map", "missing.js"].map((name) => editor(`/editor/assets/${name}`).then((r) => r.status)));
  out.assetLogo = await editor("/editor/assets/logo").then((r) => r.status);
  const editorSource = await import("node:fs").then((fs) => fs.readFileSync(`${import.meta.dirname}/editor/src/browser/body_editor.js`, "utf8"));
  out.assetPrompts = editorSource.includes("window.prompt");
  out.assetPopover = editorSource.includes("data-popover");

  out.crossSite =await editor("/editor/Article/id/first/Publish", { method: "POST", body: "", headers: { ...form, Origin: "http://evil.test" } }).then((r) => r.status);

  const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==", "base64");
  const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 16, 0x4a, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0]);
  const digest = (bytes, ext) => `${createHash("sha256").update(bytes).digest("hex")}.${ext}`;
  const upload = (bytes, { alt = "A cat", type = "image/png", name = "cat.png", as: who = editor, headers = {} } = {}) => {
    const body = new FormData();
    body.append("alt", alt);
    body.append("file", new Blob([bytes], { type }), name);
    return who("/editor/media", { method: "POST", body, headers: { Origin: "http://site.test", ...headers } });
  };
  const verbs = () => sent.filter((b) => b.verb);
  const kept = () => (readdirSync(stored, { withFileTypes: true }).filter((entry) => entry.isFile()).map((entry) => entry.name).sort());
  const pngKey = digest(png, "png");
  mkdirSync(stored, { recursive: true });
  writeFileSync(`${import.meta.dirname}/secret.txt`, "outside the picture directory");

  out.newFormMedia = out.newForm.includes('data-media="/editor/media"');
  out.pickerLoaded = await import("node:fs").then((fs) => fs.existsSync(`${import.meta.dirname}/editor/src/browser/media_picker.js`));

  sent = [];
  const first = await upload(png);
  out.upload = { status: first.status, json: await first.json(), sent: verbs(), kept: kept(), expectedKey: pngKey };

  sent = [];
  const again = await upload(png);
  out.uploadAgain = { status: again.status, json: await again.json(), sent: verbs(), kept: kept() };

  sent = [];
  const svg = Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>');
  out.svg = {
    asSvg: (await upload(svg, { type: "image/svg+xml", name: "x.svg" })).status,
    asPng: (await upload(svg, { type: "image/png", name: "x.png" })).status,
    text: (await upload(Buffer.from("not a picture"), { type: "image/jpeg", name: "x.jpg" })).status,
    sent: verbs(), kept: kept(),
  };

  const big = Buffer.concat([png, Buffer.alloc(5 * 1024 * 1024)]);
  const tooBig = await upload(big);
  const huge = await upload(Buffer.concat([png, Buffer.alloc(5 * 1024 * 1024 + 200_000)]));
  out.oversize = { status: tooBig.status, huge: huge.status, sent: verbs(), kept: kept() };

  const noAlt = await upload(jpeg, { alt: "  " });
  out.noAlt = { status: noAlt.status, json: await noAlt.json(), sent: verbs(), kept: kept() };

  refusal = "RegisterPicture refused: a picture has alt text";
  const refusedByDomain = await upload(jpeg, { alt: "A dog" });
  out.domainRefusal = { status: refusedByDomain.status, json: await refusedByDomain.json() };
  refusal = null;

  const noFile = new FormData();
  noFile.append("alt", "Nothing");
  out.noFile = await editor("/editor/media", { method: "POST", body: noFile, headers: { Origin: "http://site.test" } }).then((r) => r.status);
  out.notMultipart = await editor("/editor/media", { method: "POST", body: "alt=x", headers: form }).then((r) => r.status);

  sent = [];
  const listed = await editor("/editor/media");
  out.listing = { status: listed.status, json: await listed.json(), sent: [...sent] };

  const served = await editor(`/editor/media/${pngKey}`);
  out.serve = {
    status: served.status, type: served.headers.get("content-type"), nosniff: served.headers.get("x-content-type-options"),
    length: served.headers.get("content-length"), same: Buffer.from(await served.arrayBuffer()).equals(png),
  };
  out.traversal = [];
  for (const key of ["..%2F..%2Fsecret.txt", "%2e%2e%2fsecret.txt", "secret.txt", `..%2F${pngKey}`, "A".repeat(64) + ".png", `${"0".repeat(64)}.png`, `${pngKey}.svg`]) {
    out.traversal.push((await editor(`/editor/media/${key}`)).status);
  }
  out.mediaAnonymous = [await call(`/editor/media/${pngKey}`).then((r) => r.status), await call("/editor/media").then((r) => r.status)];
  out.uploadAnonymous = await upload(png, { as: call, headers: { Origin: "http://site.test" } }).then((r) => r.status);
  out.uploadCrossSite = await upload(png, { headers: { Origin: "http://evil.test" } }).then((r) => r.status);

  // The theme scripts, run against a stand-in page: the choice is applied from storage before paint, and
  // the button switches it, remembers it, and says what pressing it would do.
  const page = () => {
    const attributes = {};
    return { attributes, classList: { add() {} }, setAttribute(name, value) { attributes[name] = value; }, getAttribute: (name) => attributes[name] ?? null };
  };
  const applied = async (storage) => {
    const documentElement = page();
    globalThis.document = { documentElement };
    globalThis.window = { localStorage: storage };
    await import(`./editor/src/ui/theme.js?run=${Math.random()}`);
    return documentElement.attributes["data-theme"] ?? null;
  };
  out.themeApplied = {
    saved: await applied({ getItem: () => "dark" }),
    blocked: await applied({ getItem: () => { throw new Error("blocked"); } }),
    script: out.assetLinks.head,
  };
  const remembered = [];
  const handlers = [];
  const button = { attrs: {}, innerHTML: "", title: "", setAttribute(name, value) { this.attrs[name] = value; }, getAttribute(name) { return this.attrs[name]; }, addEventListener(type, run) { handlers.push(run); } };
  const root = page();
  globalThis.document = {
    documentElement: root, getElementById: () => null, addEventListener() {}, querySelectorAll: () => [],
    querySelector: (selector) => (selector === "[data-theme-toggle]" ? button : null),
  };
  globalThis.window = { localStorage: { setItem: (key, value) => remembered.push([key, value]) }, matchMedia: () => ({ matches: false, addEventListener() {} }) };
  const shell = await import("./editor/src/browser/shell.js");
  shell.enhanceShell();
  const labels = [button.attrs["aria-label"]];
  const chosen = [];
  for (let time = 0; time < 2; time += 1) {
    handlers[0]();
    labels.push(button.attrs["aria-label"]);
    chosen.push(root.attributes["data-theme"]);
  }
  out.themeToggle = { stored: remembered, attributes: chosen, labels };

  members = [];
  clock += 61_000;
  out.revoked = await editor("/editor").then((r) => [r.status, r.headers.get("location")]);

  console.log(JSON.stringify(out));
JS

# The same app for a chapter with no picture aggregate (the Editor row skips it): no upload.
EDITOR_BARE_SCENARIO = <<~JS.freeze
  import { accountToken } from "@hecks/client";
  import { createApp } from "./editor/src/app.ts";

  const SECRET = "scenario-secret";
  const now = () => 1_800_000_000_000;
  const fetch = async (url) => ({ ok: true, status: 200, json: async () => (new URL(url).pathname === "/members" ? [{ email: "ed@example.org", role: "Admin" }] : { instances: {}, refusals: [] }) });
  const app = createApp({ fetch, secret: SECRET, url: "http://host.test", now });
  const call = (path, init = {}) => app(new Request(`http://site.test${path}`, init));
  const token = accountToken(SECRET, "ed@example.org", 60, { now });
  const cookie = (await call(`/editor/api/sso?token=${token}`)).headers.get("set-cookie").split(";")[0];
  const editor = (path, init = {}) => call(path, { ...init, headers: { cookie } });
  const out = {};

  out.form = await editor("/editor/Article/new/Draft").then((r) => r.text());
  out.mediaList = await editor("/editor/media").then((r) => r.status);
  out.noBuild = await editor("/editor/assets/editor.css").then((r) => r.status);
  out.unlinked = !out.form.includes("editor.css") && !out.form.includes("editor.js");

  console.log(JSON.stringify(out));
JS

# The editor of one chapter whose pictures are kept in another (the row's `media`): the upload, the
# listing and the picker's address all go to the picture chapter's own domain.
EDITOR_ELSEWHERE_SCENARIO = <<~JS.freeze
  import { accountToken } from "@hecks/client";
  import { mkdirSync } from "node:fs";
  import { createApp } from "./editor/src/app.ts";
  import { diskStorage } from "./editor/src/media/storage.ts";

  const SECRET = "scenario-secret";
  const now = () => 1_800_000_000_000;
  const instances = {};
  let sent = [];
  const fetch = async (url, init) => {
    if (new URL(url).pathname === "/members") return { ok: true, status: 200, json: async () => [{ email: "ed@example.org", role: "Admin" }] };
    const body = JSON.parse(init.body);
    sent.push(body);
    if (body.verb) instances[`Library::MediaItem#${body.with.key.value}`] = { ...body.with };
    const queries = body.query ? { queries: [{ query: body.query, rows: Object.values(instances) }] } : {};
    return { ok: true, status: 200, json: async () => ({ instances: structuredClone(instances), refusals: [], ...queries }) };
  };
  const stored = `${import.meta.dirname}/stored`;
  mkdirSync(stored, { recursive: true });
  const app = createApp({ fetch, secret: SECRET, url: "http://host.test", now, storage: diskStorage(stored) });
  const call = (path, init = {}) => app(new Request(`http://site.test${path}`, init));
  const token = accountToken(SECRET, "ed@example.org", 60, { now });
  const cookie = (await call(`/editor/api/sso?token=${token}`)).headers.get("set-cookie").split(";")[0];
  const editor = (path, init = {}) => call(path, { ...init, headers: { cookie, Origin: "http://site.test" } });
  const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==", "base64");
  const out = {};

  out.form = await editor("/editor/Article/new/Draft").then((r) => r.text());
  out.nav = await editor("/editor").then((r) => r.text());
  const body = new FormData();
  body.append("alt", "A cat");
  body.append("file", new Blob([png], { type: "image/png" }), "cat.png");
  sent = [];
  out.upload = await editor("/editor/media", { method: "POST", body }).then((r) => r.status);
  out.registered = sent.filter((entry) => entry.verb);
  sent = [];
  out.listing = await editor("/editor/media").then((r) => r.json());
  out.asked = sent.filter((entry) => entry.query);

  console.log(JSON.stringify(out));
JS

# The generated editor, run by node: the sign-in gate, the pages, the command forms and a refusal.
RSpec.describe "the generated editor, run by node" do
  let(:project) { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/editor") }

  def files
    projected = Hecks::Tools::SiteRoutes.projection(project, out: "/work/out", editor: "/work/editor")
    projected.select { |path, _| path.start_with?("/work/editor/") }.transform_keys { |path| path.delete_prefix("/work/editor/") }
  end

  def result(key)
    skip "node cannot strip TypeScript types here" unless EditorNode.available?

    EditorNode.results(files).fetch(key)
  end

  describe "the sign-in gate" do
    it "sends a visitor with no session to the site's login page, and refuses a post", :aggregate_failures do
      expect(result("anonymousGet")).to eq([302, "/admin-login"])
      expect(result("anonymousPost")).to eq(403)
    end

    it "does not take a forged session cookie" do
      expect(result("forgedCookie")).to eq([302, "/admin-login"])
    end

    it "refuses a token for an account the members list does not admit, and a token that does not verify", :aggregate_failures do
      expect(result("notAnEditor")).to eq(403)
      expect(result("badToken")).to eq(401)
    end

    it "starts the editor's own session cookie from a valid hand-off" do
      expect(result("cookie")).to eq("press_editor")
    end

    it "asks the members list again, so removing someone locks them out" do
      expect(result("revoked")).to eq([302, "/admin-login"])
    end

    it "refuses a post the browser says came from another site" do
      expect(result("crossSite")).to eq(403)
    end
  end

  describe "the pages" do
    it "shows a navigation of every aggregate, with how many each holds", :aggregate_failures do
      home = result("home")

      expect(home).to include('href="/editor/Article"', 'href="/editor/Masthead"')
      expect(home).to include('<span class="ml-auto text-xs text-muted tabular-nums">1</span>')
    end

    it "marks the page the person is on in the navigation, and only that one", :aggregate_failures do
      list = result("list")["html"]

      expect(list).to include('<a href="/editor/Article" aria-current="page">')
      expect(list).not_to include('<a href="/editor/Masthead" aria-current="page">')
      expect(result("home")).to include('<a href="/editor" aria-current="page">')
    end

    it "names who is signed in and their role, escaped", :aggregate_failures do
      expect(result("home")).to include("ed@example.org", "Admin")
      expect(result("escapedPerson")).to include("&#60;i&#62;@example.org")
      expect(result("escapedPerson")).not_to include("<i>@example.org")
    end

    it "has a skip link, one main landmark, a banner and a labelled navigation, in a document with a language",
       :aggregate_failures do
      home = result("home")

      expect(home).to include('<html lang="en">', 'href="#main"', '<main id="main"', '<header class="navbar',
                              'aria-label="Sections"')
      expect(home.scan("<main").size).to eq(1)
    end

    it "gives each page a title of its own, and exactly one first-level heading", :aggregate_failures do
      expect(result("detail")).to include("<title>first - Press editor</title>")
      expect(result("list")["html"]).to include("<title>Articles - Press editor</title>")
      expect(result("list")["html"].scan("<h1").size).to eq(1)
    end

    it "renders the rows of the query it asked the host, with the status as words and a shape", :aggregate_failures do
      list = result("list")

      expect(list["status"]).to eq(200)
      expect(list["html"]).to include('href="/editor/Article/id/first"', "First piece", "badge badge-soft gap-1 font-semibold")
      expect(list["html"]).to match(%r{<span class="badge[^"]*"><svg class="icon"[^>]*><use href="#i-dot"/></svg>Draft</span>})
      expect(list["sent"]).to eq([{ "query" => "Press::Article.Published", "args" => {} }])
    end

    it "gives a list headings that sort, a filter, and a count", :aggregate_failures do
      html = result("list")["html"]

      expect(html).to include("data-sortable", 'data-sort="text"', "data-filter", "1 article")
    end

    it "says an empty list is empty in one sentence, with the command that makes the first one", :aggregate_failures do
      html = result("mastheadList")

      expect(html).to include("No mastheads yet. Add the first one.", "<span>Establish masthead</span>")
      expect(result("emptyList")).not_to include("<table")
    end

    it "shows an instance with its state as a badge and a rich-text body read-only", :aggregate_failures do
      detail = result("detail")

      expect(detail).to include("Draft</span>", '<div class="prose"><p><strong>Hi &#60;i&#62;</strong></p></div>')
      expect(detail).to include('action="/editor/Article/id/first/Publish"', 'data-copy="first"')
    end

    it "shows the status and the commands that apply in a margin panel", :aggregate_failures do
      detail = result("detail")

      expect(detail).to include('aria-label="Status and actions"', ">Status</h2>", ">Actions</h2>")
      expect(detail).to include('href="/editor/Article/id/first/Revise"')
    end

    it "shows the rich-text widget on the form that edits a body, filled from the instance", :aggregate_failures do
      form = result("revisePage")

      expect(form).to include("data-body-editor", 'name="body.blocks.0.spans.0.text" value="Hi &#60;i&#62;"')
      expect(form).to include("Editing this text needs scripts turned on in the browser.")
    end

    it "never lets a body's text become markup", :aggregate_failures do
      detail = result("detail")

      expect(detail).not_to include("<i>")
      expect(detail).to include("Hi &#60;i&#62;")
    end

    it "serves a stylesheet and scripts that the page names by version", :aggregate_failures do
      expect(result("assetLinks")).to eq("sheet" => true, "script" => true, "head" => true)
      expect(result("asset")["theme"]).to eq([200, "text/javascript; charset=utf-8", "//"])
    end

    it "sends each file with an ETag that names its version, kept for good under that version", :aggregate_failures do
      asset = result("asset")

      expect([asset["status"], asset["type"]]).to eq([200, "text/css; charset=utf-8"])
      expect(asset["versionIsEtag"]).to be(true)
      expect(asset["versioned"]).to eq("private, max-age=31536000, immutable")
      expect(asset["nosniff"]).to eq("nosniff")
    end

    it "revalidates a file asked for without its version, and answers 304 when the browser holds it", :aggregate_failures do
      asset = result("asset")

      expect(asset["plain"]).to eq("private, no-cache")
      expect(asset["notModified"]).to eq([304, 0])
    end

    it "serves files to a signed-in editor only, and no file that is not one of its own", :aggregate_failures do
      expect(result("assetAnonymous")).to eq(302)
      expect(result("assetUnknown")).to eq([404, 404, 404, 404])
      expect(result("assetLogo")).to eq(404)
    end

    it "sends every page with a policy that allows no inline script or style and no other origin", :aggregate_failures do
      headers = result("detailHeaders")
      policy = headers["content-security-policy"]

      expect(policy).to include("default-src 'none'", "script-src 'self'", "style-src 'self'", "frame-ancestors 'none'")
      expect(policy).not_to match(/unsafe-inline|unsafe-eval|https?:/)
      expect(headers).to include("cache-control" => "no-store", "content-type" => "text/html; charset=utf-8")
    end

    it "writes no style attribute and no inline script into a page", :aggregate_failures do
      pages = %w[home detail revisePage newForm].map { |key| result(key) }.join

      expect(pages).not_to match(/\sstyle=|<style|<script>|\sonclick=/)
    end

    it "offers a lifecycle move only from the states it applies in" do
      expect(result("detail")).not_to include("/Restore")
    end

    it "builds a creating command's form from its attributes, with a blank row to fill", :aggregate_failures do
      form = result("newForm")

      expect(form).to include('name="slug.value"', 'name="sections.0.links.0.label"', 'name="tags.0.value"')
      expect(form).to include("optional</span>", 'aria-required="true"', "data-repeat", "data-row")
    end

    it "marks the fields that must be filled and says so under the form", :aggregate_failures do
      form = result("newForm")

      expect(form).to include('title="Required" aria-hidden="true">*</span>', "* </span> Required".sub("* </span>", "*</span>"))
    end

    it "answers 404 for an instance that is not there" do
      expect(result("missing")).to eq(404)
    end
  end

  describe "a destructive command" do
    it "asks first, in a native dialog the page carries, and leaves the other commands as plain buttons", :aggregate_failures do
      detail = result("detail")

      expect(detail).to include('data-confirm="confirm-DiscardDraft"', '<dialog class="modal" id="confirm-DiscardDraft"')
      expect(detail).to include('aria-labelledby="confirm-DiscardDraft-title"', 'formmethod="dialog"', "Discard draft?")
      expect(detail).not_to include("confirm-Publish")
    end

    it "is the same question on a page of its own for a browser with no script", :aggregate_failures do
      page = result("confirmPage")

      expect(page).to include("Choose Discard draft to go ahead.", 'action="/editor/Article/id/first/DiscardDraft"')
    end
  end

  describe "the command forms" do
    it "posts a lifecycle move as its verb, to the instance, as the role the command declares", :aggregate_failures do
      publish = result("publish")

      expect(publish["sent"]).to eq([{ "verb" => "Press::Article.Publish", "to" => "first", "with" => {}, "role" => "Editor" }])
      expect([publish["status"], publish["location"]]).to eq([303, "/editor/Article/id/first"])
    end

    DRAFTED = {
      "slug" => { "value" => "second" }, "headline" => { "value" => "Second piece" },
      "byline" => { "name" => "Bo", "contact" => "bo@example.org" }, "tags" => [{ "value" => "a" }],
      "sections" => [{ "heading" => "Links", "links" => [{ "label" => "Home", "url" => "/" }] }],
      "body" => { "blocks" => [{ "kind" => "paragraph", "indent" => 1, "items" => [],
                                 "spans" => [{ "text" => "Hello", "marks" => [{ "name" => "bold" }] }] }] }
    }.freeze

    it "posts a creating command with its nested value objects and rows, leaving out what is blank", :aggregate_failures do
      create = result("create")

      expect(create["sent"].first["with"]).to eq(DRAFTED)
      expect(create["sent"].first).not_to have_key("to")
      expect([create["status"], create["location"]]).to eq([303, "/editor/Article/id/second"])
    end

    it "labels each button with a sentence-case verb, and makes a creating one say what it makes", :aggregate_failures do
      expect(result("detail")).to include(">Publish</button>", ">Save draft</a>", ">Revise</a>")
      expect(result("list")["html"]).to include("<span>Draft article</span>")
    end

    it "disables the submit button while the form is sent, and has a sticky bar with a cancel", :aggregate_failures do
      form = result("revisePage")

      expect(form).to include("data-busy", "sticky bottom-0", 'href="/editor/Article/id/first">Cancel</a>')
    end
  end

  describe "a notice after a command" do
    COOKIE = %r{\Apress_editor_flash=[\w-]+\.[\w-]+; Path=/editor; HttpOnly; SameSite=Lax; Max-Age=60}

    it "is carried to the next page by a short-lived signed cookie" do
      expect(result("publish")["setCookie"]).to match(COOKIE)
    end

    it "shows once: the next page has it, clears the cookie in the same response, and the page after has none",
       :aggregate_failures do
      notice = result("notice")

      expect(notice["html"]).to include('role="status"', "<p>Published.</p>")
      expect(notice["setCookie"]).to include("press_editor_flash=;", "Max-Age=0")
      expect(result("noticeGone")).not_to include("<p>Published.</p>")
    end

    it "is not shown when it was made up, or has expired", :aggregate_failures do
      expect(result("noticeForged")).not_to include("Forged.")
      expect(result("noticeExpired")).not_to include("Published.")
    end

    it "escapes what it says", :aggregate_failures do
      escaped = result("noticeEscaped")

      expect(escaped).to include("&#60;img src=x onerror=alert(1)&#62;")
      expect(escaped).not_to include("<img src=x")
    end

    it "uses the same verb as the button: the one that says Publish leaves Published." do
      expect(result("notice")["html"]).to include("Published.")
    end
  end

  describe "a refusal" do
    it "is shown inline on the form, with the person's input kept, and is not a redirect", :aggregate_failures do
      refused = result("refused")

      expect(refused["status"]).to eq(422)
      expect(refused["html"]).to include('data-refusal><svg class="icon"', "Revise refused: an article has a headline</p>")
      expect(refused["html"]).to include('name="byline.name" value="Ann"')
    end

    it "is announced as well by a notice that says what was not applied", :aggregate_failures do
      html = result("refused")["html"]

      expect(html).to include('role="alert" data-toast', "Revise was not applied. Fix what is marked and try again.")
    end
  end

  describe "a refusal's words" do
    it "reads a given as the condition that was not met, not as the reason", :aggregate_failures do
      html = result("publishNoDraft")["html"]

      expect(result("publishNoDraft")["status"]).to eq(422)
      expect(html).to include("Not allowed unless an edit is saved.</p>")
    end

    it "reads an invariant as the field and the rule, never as the raw offered value", :aggregate_failures do
      html = result("invariant")["html"]

      expect(html).to include("headline: an article has a headline.</p>")
      expect(html).not_to include("given")
    end

    it "marks the field an invariant names, and gives its message beside it", :aggregate_failures do
      html = result("invariant")["html"]

      expect(html).to include('aria-invalid="true" aria-describedby="f-headline-value-error"')
      expect(html).to include('id="f-headline-value-error">an article has a headline.</p>')
    end
  end

  describe "a draft, saved and promoted" do
    it "starts a draft's form from the body the article holds, until a draft is saved", :aggregate_failures do
      expect(result("draftReviseForm")).to include('name="draft_body.blocks.0.spans.0.text" value="Hi &#60;i&#62;"')
      expect(result("afterSave")).to include('name="draft_body.blocks.0.spans.0.text" value="Edited"')
    end

    it "offers no field for the argument that only clears, on a form that has no other argument", :aggregate_failures do
      expect(result("draftForms")).to include('action="/editor/Article/id/first/PublishDraft"')
      expect(result("draftForms")).not_to include('name="nothing')
    end

    it "sends nothing for it, and judges the promotion applied by the state that comes back", :aggregate_failures do
      promoted = result("promoted")

      sent = { "verb" => "Press::Article.PublishDraft", "to" => "first", "with" => {}, "role" => "Editor" }
      expect(promoted["sent"]).to eq([sent])
      expect([promoted["status"], promoted["location"]]).to eq([303, "/editor/Article/id/first"])
    end

    it "shows the promoted body and no draft afterwards", :aggregate_failures do
      expect(result("afterPromote")).to include('name="body.blocks.0.spans.0.text" value="Edited"')
      expect(result("afterPromoteDetail")).to include('Draft body</dt><dd class="min-w-0 break-words"><span class="text-muted">')
    end
  end

  describe "signing in and out" do
    it "sends the person to the editor's clean path once the token is spent" do
      expect(result("signInRedirect")).to eq([302, "/editor"])
    end

    it "ends the session on a post to the logout path, and sends the person to the login page", :aggregate_failures do
      logout = result("logout")

      expect([logout["status"], logout["location"]]).to eq([303, "/admin-login"])
      expect(logout["cookie"]).to include("press_editor=;", "Max-Age=0")
    end

    it "offers the button in the header, and refuses it from another site", :aggregate_failures do
      expect(result("signOutButton")).to be(true)
      expect(result("logoutCrossSite")).to eq(403)
    end
  end

  describe "the writing surface's link and picture forms" do
    it "asks in a popover attached to the toolbar, never with the browser's blocking prompt", :aggregate_failures do
      expect(result("assetPopover")).to be(true)
      expect(result("assetPrompts")).to be(false)
    end
  end

  # The browser scripts that need no page: the theme the person chose is applied before paint and kept
  # where storage allows, and not lost when storage is blocked.
  describe "the theme" do
    it "is applied from the remembered choice, and follows the system when storage is blocked", :aggregate_failures do
      expect(result("themeApplied")).to eq("saved" => "editor-dark", "blocked" => nil, "script" => true)
    end

    it "is switched by the button, remembered, and shown by the button's own icon", :aggregate_failures do
      toggle = result("themeToggle")

      expect(toggle["stored"]).to eq([%w[editor-theme dark], %w[editor-theme light]])
      expect(toggle["attributes"]).to eq(%w[editor-dark editor-light])
      expect(toggle["labels"]).to eq(["Switch to the dark theme", "Switch to the light theme", "Switch to the dark theme"])
    end
  end

  # Pictures: an upload, a listing and a stored file, run by node against a fake host and a temp
  # directory, and the same editor for a chapter that has no picture aggregate.
  describe "pictures" do
    let(:project) { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/editor") }

    # The editor's files for `source`, or for the fixture with its picture aggregate skipped.
    def files(skipping: false)
      return projected(project) unless skipping

      Dir.mktmpdir("cms_editor_bare") do |dir|
        FileUtils.cp_r(File.join(project, "."), dir)
        file = File.join(dir, "bluebook/press_site.bluebook")
        File.write(file, File.read(file).sub('title: "Press editor"', 'title: "Press editor", skip: "MediaItem"'))
        projected(dir)
      end
    end

    def projected(source)
      all = Hecks::Tools::SiteRoutes.projection(source, out: "/work/out", editor: "/work/editor")
      all.select { |path, _| path.start_with?("/work/editor/") }.transform_keys { |path| path.delete_prefix("/work/editor/") }
    end

    def result(key)
      skip "node cannot strip TypeScript types here" unless EditorNode.available?

      EditorNode.results(files).fetch(key)
    end

    def bare(key)
      skip "node cannot strip TypeScript types here" unless EditorNode.available?

      EditorNode.bare_results { files(skipping: true) }.fetch(key)
    end

    describe "an upload" do
      it "stores the bytes under a key made from their digest and returns it", :aggregate_failures do
        upload = result("upload")

        expect(upload["status"]).to eq(201)
        expect(upload["json"]).to include("key" => upload["expectedKey"], "alt" => "A cat", "mime" => "image/png")
        expect(upload["kept"]).to eq([upload["expectedKey"]])
      end

      it "registers the picture with the domain: its key, alt text, type and size, and never its bytes" do
        key = result("upload")["expectedKey"]
        record = { "key" => { "value" => key }, "alt" => { "value" => "A cat" }, "mime_type" => { "value" => "image/png" },
                   "width" => { "value" => 1 }, "height" => { "value" => 1 } }

        registered = { "verb" => "Press::MediaItem.RegisterPicture", "with" => record, "role" => "Editor" }
        expect(result("upload")["sent"]).to eq([registered])
      end

      it "answers with the picture already registered when the same bytes come again", :aggregate_failures do
        again = result("uploadAgain")

        expect(again["status"]).to eq(200)
        expect(again["sent"]).to be_empty
      end

      it "refuses an SVG, bytes that are not a picture, and a type the bytes do not bear out", :aggregate_failures do
        svg = result("svg")

        expect(svg.values_at("asSvg", "asPng", "text")).to eq([415, 415, 415])
        expect([svg["sent"], svg["kept"].size]).to eq([[], 1])
      end

      it "refuses a body over the size cap, with or without the form's framing", :aggregate_failures do
        oversize = result("oversize")

        expect(oversize.values_at("status", "huge")).to eq([413, 413])
        expect([oversize["sent"], oversize["kept"].size]).to eq([[], 1])
      end

      it "refuses a picture with no alt text inline, keeping and registering nothing", :aggregate_failures do
        no_alt = result("noAlt")

        expect(no_alt["status"]).to eq(422)
        expect(no_alt["json"]["error"]).to include("alt text")
        expect([no_alt["sent"], no_alt["kept"].size]).to eq([[], 1])
      end

      it "shows the domain's own refusal inline" do
        expect(result("domainRefusal")).to eq("status" => 422,
                                              "json"   => { "error" => "RegisterPicture refused: a picture has alt text" })
      end

      it "refuses an upload with no file and a body that is not multipart", :aggregate_failures do
        expect(result("noFile")).to eq(400)
        expect(result("notMultipart")).to eq(400)
      end

      it "is for a signed-in editor, from this site only", :aggregate_failures do
        expect(result("uploadAnonymous")).to eq(403)
        expect(result("uploadCrossSite")).to eq(403)
      end
    end

    describe "the registered pictures" do
      it "are listed from the aggregate's listing query, each with the address the adapter shows it at", :aggregate_failures do
        listing = result("listing")
        key = result("upload")["expectedKey"]

        expect(listing["json"]["pictures"]).to eq([{ "key" => key, "alt" => "A cat", "mime" => "image/png",
"url" => "/editor/media/#{key}" }])
        expect(listing["sent"]).to eq([{ "query" => "Press::MediaItem.Pictures", "args" => {} }])
      end
    end

    describe "a stored picture" do
      it "is served to a signed-in editor with its own type and no sniffing" do
        expect(result("serve")).to include("status" => 200, "type" => "image/png", "nosniff" => "nosniff", "same" => true)
      end

      it "is not served for a key that is not one the editor made, so no path leaves the directory" do
        expect(result("traversal")).to all(eq(404))
      end

      it "is not served to a visitor with no session" do
        expect(result("mediaAnonymous")).to eq([302, 302])
      end
    end

    describe "the widget" do
      it "is given the picker's address and script when the chapter registers pictures", :aggregate_failures do
        expect(result("newFormMedia")).to be(true)
        expect(result("pickerLoaded")).to be(true)
      end

      it "keeps the prompt, and offers no upload, when the chapter has no picture aggregate", :aggregate_failures do
        expect(bare("form")).to include("data-body-editor")
        expect(bare("form")).not_to include("data-media")
        expect(bare("mediaList")).to eq(404)
      end

      it "links no stylesheet or script before the build has written them, and serves none", :aggregate_failures do
        expect(bare("unlinked")).to be(true)
        expect(bare("noBuild")).to eq(404)
      end

      it "generates none of the upload's files for such a chapter" do
        expect(files(skipping: true).keys.grep(/media/)).to be_empty
      end
    end
  end

  # Pictures kept in another chapter of the project's domain: the Editor row's `media` names it, so a
  # body in one chapter uses the pictures of the other (the chapter that holds bodies has no picture
  # aggregate of its own, and the picture chapter has no bodies).
  describe "with its pictures in another chapter" do
    def library = <<~RUBY
      Hecks.bluebook "Library" do
        vision "The pictures a small publisher keeps."
        core

        aggregate "MediaItem" do
          description "A picture the publisher has uploaded: its record only."
          identified_by :key

          value_object("PictureKey") { attribute :value, String }
          value_object("AltText") { attribute :value, String }
          value_object("MimeType") { attribute :value, String }

          attribute :key,       PictureKey
          attribute :alt,       AltText
          attribute :mime_type, MimeType

          command "RegisterPicture" do
            role "Editor"
            goal "Record a picture that has been uploaded"
            attribute :key,       PictureKey
            attribute :alt,       AltText
            attribute :mime_type, MimeType
            emits "PictureRegistered"
          end

          query("Pictures") { description "Every registered picture." }
        end
      end
    RUBY

    let(:fixture) { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/editor") }

    # The fixture with its own picture aggregate skipped, and a second chapter that holds one.
    def project_with(row_edit)
      Dir.mktmpdir("cms_editor_elsewhere") do |dir|
        FileUtils.cp_r(File.join(fixture, "."), dir)
        File.write(File.join(dir, "domain/bluebook/library.bluebook"), library)
        file = File.join(dir, "bluebook/press_site.bluebook")
        File.write(file,
                   File.read(file).sub('title: "Press editor"', "title: \"Press editor\", skip: \"MediaItem\", #{row_edit}"))
        yield dir
      end
    end

    def editor_files(dir)
      all = Hecks::Tools::SiteRoutes.projection(dir, out: "/work/out", editor: "/work/editor")
      all.select { |path, _| path.start_with?("/work/editor/") }.transform_keys { |path| path.delete_prefix("/work/editor/") }
    end

    def run
      skip "node cannot strip TypeScript types here" unless EditorNode.available?

      project_with('media: "Library"') { |dir| EditorNode.run(editor_files(dir), EDITOR_ELSEWHERE_SCENARIO) }
    end

    it "gives the body's widget the picker, though the chapter has no picture aggregate of its own", :aggregate_failures do
      out = run

      expect(out["form"]).to include('data-media="/editor/media"')
      expect(out["nav"]).not_to include("MediaItem")
    end

    it "registers an upload with the picture chapter's domain", :aggregate_failures do
      out = run

      expect(out["upload"]).to eq(201)
      expect(out["registered"].map { |sent| sent["verb"] }).to eq(["Library::MediaItem.RegisterPicture"])
    end

    it "lists the pictures from the picture chapter's query" do
      out = run

      expect(out["asked"]).to eq([{ "query" => "Library::MediaItem.Pictures", "args" => {} }])
    end

    it "is refused when the row names this editor's own chapter" do
      project_with('media: "Press"') do |dir|
        expect { editor_files(dir) }.to raise_error(SystemExit, /is this editor's own chapter/)
      end
    end

    it "is refused when the row names a chapter the domain does not declare" do
      project_with('media: "Nowhere"') do |dir|
        expect { editor_files(dir) }.to raise_error(SystemExit, /declares no chapter Nowhere/)
      end
    end
  end
end
