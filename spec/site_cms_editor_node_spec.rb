require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "hecks/tools"
require "hecks/tools/site_routes"

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
  out.list = { status: list.status, html: await list.text(), sent: [...sent] };
  out.detail = await editor("/editor/Article/id/first").then((r) => r.text());
  out.missing = await editor("/editor/Article/id/none").then((r) => r.status);
  out.newForm = await editor("/editor/Article/new/Draft").then((r) => r.text());

  sent = [];
  const publish = await editor("/editor/Article/id/first/Publish", post("", ""));
  out.publish = { status: publish.status, location: publish.headers.get("location"), sent: sent.filter((b) => b.verb) };

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

  out.draftForms = await editor("/editor/Article/id/first").then((r) => r.text());
  sent = [];
  const noDraft = await editor("/editor/Article/id/first/PublishDraft", post("", ""));
  out.publishNoDraft = { status: noDraft.status, html: await noDraft.text() };
  out.saved = await editor("/editor/Article/id/first/SaveDraft", post("", "draft_body.blocks.0.kind=paragraph&draft_body.blocks.0.spans.0.text=Edited"))
    .then((r) => [r.status, r.headers.get("location")]);
  out.afterSave = await editor("/editor/Article/id/first").then((r) => r.text());
  sent = [];
  const promoted = await editor("/editor/Article/id/first/PublishDraft", post("", ""));
  out.promoted = { status: promoted.status, location: promoted.headers.get("location"), sent: sent.filter((b) => b.verb) };
  out.afterPromote = await editor("/editor/Article/id/first").then((r) => r.text());

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

  const script = await editor("/editor/assets/body_widget.js");
  const scriptText = await script.text();
  out.asset = { status: script.status, type: script.headers.get("content-type"), starts: scriptText.slice(0, 2) };
  out.assetPrompts = scriptText.includes("window.prompt");
  out.assetPopover = scriptText.includes("data-popover");
  out.assetAnonymous = await call("/editor/assets/body_widget.js").then((r) => r.status);
  out.assetUnknown = await editor("/editor/assets/app.ts").then((r) => r.status);

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
  out.pickerAsset = await editor("/editor/assets/media_picker.js").then((r) => [r.status, r.headers.get("content-type")]);

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
  out.picker = await editor("/editor/assets/media_picker.js").then((r) => r.status);
  out.widget = await editor("/editor/assets/body_widget.js").then((r) => r.status);

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

# Runs the generated editor under node, with @hecks/client built from its TypeScript source into the
# sandbox's node_modules (node does not strip types under node_modules, so the client is
# transformed to plain modules first).
module EditorNode
  STRIP = <<~JS.freeze
    import { readdirSync, readFileSync, writeFileSync } from "node:fs";
    import { stripTypeScriptTypes } from "node:module";
    const [src, out] = process.argv.slice(2);
    for (const name of readdirSync(src).filter((file) => file.endsWith(".ts"))) {
      const code = stripTypeScriptTypes(readFileSync(`${src}/${name}`, "utf8"), { mode: "transform" });
      writeFileSync(`${out}/${name.replace(/\\.ts$/, ".mjs")}`, code.replace(/(from\\s+"\\.\\/[^"]+)\\.js"/g, '$1.mjs"'));
    }
  JS

  CLIENT = File.join(InMemoryDomain::ROOT, "packages/hecks-client")
  ENVIRONMENT = { "NODE_NO_WARNINGS" => "1" }.freeze

  module_function

  # @return [Boolean] whether node can strip TypeScript types, which the sandbox relies on
  def available?
    probe = 'process.exit(typeof require("node:module").stripTypeScriptTypes === "function" ? 0 : 1)'
    out, status = Open3.capture2e(ENVIRONMENT, "node", "-e", probe)
    status.success? && out.empty?
  rescue SystemCallError
    false
  end

  # @param files [Hash{String => String}] the editor's files, by path relative to its directory
  # @return [Hash{String => Object}] what the scenario printed, parsed
  def run(files, scenario = EDITOR_NODE_SCENARIO)
    Dir.mktmpdir("cms_editor_node") do |dir|
      install_client(dir)
      files.each { |name, text| write(File.join(dir, "editor", name), text) }
      write(File.join(dir, "scenario.mjs"), scenario)
      out, err, status = Open3.capture3(ENVIRONMENT, "node", File.join(dir, "scenario.mjs"))
      raise "the editor scenario failed:\n#{err}" unless status.success?

      JSON.parse(out)
    end
  end

  def install_client(dir)
    modules = File.join(dir, "node_modules/@hecks/client")
    FileUtils.mkdir_p(modules)
    write(File.join(dir, "strip.mjs"), STRIP)
    _, err, status = Open3.capture3(ENVIRONMENT, "node", File.join(dir, "strip.mjs"), File.join(CLIENT, "src"), modules)
    raise "could not prepare @hecks/client:\n#{err}" unless status.success?

    manifest = { "name" => "@hecks/client", "type" => "module", "exports" => "./index.mjs" }
    write(File.join(modules, "package.json"), JSON.generate(manifest))
  end

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  # The scenario's results, run once for the examples below.
  def results(files)
    @results ||= run(files)
  end

  # The results of the scenario for a chapter with no picture aggregate; the block gives its files.
  def bare_results
    @bare_results ||= run(yield, EDITOR_BARE_SCENARIO)
  end
end

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
    it "shows a nav of every aggregate" do
      expect(result("home")).to include('href="/editor/Article"', 'href="/editor/Masthead"')
    end

    it "renders the rows of the query it asked the host", :aggregate_failures do
      list = result("list")

      expect(list["status"]).to eq(200)
      expect(list["html"]).to include('href="/editor/Article/id/first"', "First piece", '<span class="badge">draft</span>')
      expect(list["sent"]).to eq([{ "query" => "Press::Article.Published", "args" => {} }])
    end

    it "shows an instance with its state as a badge and a rich-text body read-only", :aggregate_failures do
      detail = result("detail")

      expect(detail).to include('<span class="badge">draft</span>')
      expect(detail).to include('<div class="body"><p><strong>Hi &#60;i&#62;</strong></p></div>')
      expect(detail).to include('action="/editor/Article/id/first/Publish"', 'name="byline.name"')
    end

    it "shows the rich-text widget on a form that edits a body, filled from the instance", :aggregate_failures do
      detail = result("detail")

      expect(detail).to include("data-body-editor", 'name="body.blocks.0.spans.0.text" value="Hi &#60;i&#62;"')
      expect(detail).to include('<script type="module" src="/editor/assets/body_widget.js">')
    end

    it "never lets a body's text become markup", :aggregate_failures do
      detail = result("detail")

      expect(detail).not_to include("<i>")
      expect(detail).to include("Hi &#60;i&#62;")
    end

    it "serves the widget's script to a signed-in editor only", :aggregate_failures do
      expect(result("asset")).to eq("status" => 200, "type" => "text/javascript; charset=utf-8", "starts" => "//")
      expect(result("assetAnonymous")).to eq(302)
      expect(result("assetUnknown")).to eq(404)
    end

    it "offers a lifecycle move only from the states it applies in" do
      expect(result("detail")).not_to include("/Restore")
    end

    it "builds a creating command's form from its attributes, with a blank row to fill", :aggregate_failures do
      form = result("newForm")

      expect(form).to include('name="slug.value"', 'name="sections.0.links.0.label"', 'name="tags.0.value"')
      expect(form).to include("(optional)")
    end

    it "answers 404 for an instance that is not there" do
      expect(result("missing")).to eq(404)
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
  end

  describe "a refusal" do
    it "is shown inline on the form, with the person's input kept, and is not a redirect", :aggregate_failures do
      refused = result("refused")

      expect(refused["status"]).to eq(422)
      expect(refused["html"]).to include('<div class="refusal" role="alert">Revise refused: an article has a headline</div>')
      expect(refused["html"]).to include('name="byline.name" value="Ann"')
    end
  end

  describe "a refusal's words" do
    it "reads a given as the condition that was not met, not as the reason", :aggregate_failures do
      html = result("publishNoDraft")["html"]

      expect(result("publishNoDraft")["status"]).to eq(422)
      expect(html).to include('<div class="refusal" role="alert">Not allowed unless an edit is saved.</div>')
    end

    it "reads an invariant as the field and the rule, never as the raw offered value", :aggregate_failures do
      html = result("invariant")["html"]

      expect(html).to include('<div class="refusal" role="alert">headline: an article has a headline.</div>')
      expect(html).not_to include("given")
    end
  end

  describe "a draft, saved and promoted" do
    it "starts a draft's form from the body the article holds, until a draft is saved", :aggregate_failures do
      forms = result("draftForms")

      expect(forms).to include('name="draft_body.blocks.0.spans.0.text" value="Hi &#60;i&#62;"')
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
      expect(result("afterPromote")).to include("<th>draft body</th><td><em>empty</em></td>")
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

  describe "the widget's link and image forms" do
    it "asks in a popover attached to the toolbar, never with the browser's blocking prompt", :aggregate_failures do
      expect(result("assetPopover")).to be(true)
      expect(result("assetPrompts")).to be(false)
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
        expect(result("pickerAsset")).to eq([200, "text/javascript; charset=utf-8"])
      end

      it "keeps the prompt, and offers no upload, when the chapter has no picture aggregate", :aggregate_failures do
        expect(bare("form")).to include("data-body-editor")
        expect(bare("form")).not_to include("data-media")
        expect([bare("mediaList"), bare("picker"), bare("widget")]).to eq([404, 404, 200])
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
