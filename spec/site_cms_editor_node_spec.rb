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
  import { createApp } from "./editor/src/app.ts";

  const SECRET = "scenario-secret";
  let clock = 1_800_000_000_000;
  let members = [{ email: "ed@example.org", role: "Admin" }];
  let refusal = null;
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
    if (body.query) return answer({ queries: [{ query: body.query, rows: Object.values(instances) }] });
    if (body.read || refusal) return answer(refusal && !body.read ? { refusals: [{ verb: body.verb, kind: "GivenNotMet", error: refusal }] } : {});
    const [, verb] = body.verb.split(".");
    if (verb === "Draft") instances[`Press::Article#${body.with.slug.value}`] = { ...body.with, status: "draft" };
    if (verb === "Publish") instances[`Press::Article#${body.to}`].status = "published";
    return answer();
  };

  const app = createApp({ fetch, secret: SECRET, url: "http://host.test", now: () => clock });
  const token = (email) => accountToken(SECRET, email, 60, { now: () => clock });
  const form = { "Content-Type": "application/x-www-form-urlencoded", Origin: "http://site.test" };
  const call = (path, init = {}) => app(new Request(`http://site.test${path}`, init));
  const signIn = async (email) => (await call(`/editor/api/sso?token=${token(email)}`)).headers.get("set-cookie")?.split(";")[0];
  const as = (cookie) => (path, init = {}) => call(path, { ...init, headers: { cookie, ...(init.headers ?? {}) } });
  const post = (path, body) => ({ method: "POST", body, headers: form });
  const last = () => sent.at(-1);
  const out = {};

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

  const script = await editor("/editor/assets/body_widget.js");
  out.asset = { status: script.status, type: script.headers.get("content-type"), starts: (await script.text()).slice(0, 2) };
  out.assetAnonymous = await call("/editor/assets/body_widget.js").then((r) => r.status);
  out.assetUnknown = await editor("/editor/assets/app.ts").then((r) => r.status);

  out.crossSite =await editor("/editor/Article/id/first/Publish", { method: "POST", body: "", headers: { ...form, Origin: "http://evil.test" } }).then((r) => r.status);

  members = [];
  clock += 61_000;
  out.revoked = await editor("/editor").then((r) => [r.status, r.headers.get("location")]);

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
  def run(files)
    Dir.mktmpdir("cms_editor_node") do |dir|
      install_client(dir)
      files.each { |name, text| write(File.join(dir, "editor", name), text) }
      write(File.join(dir, "scenario.mjs"), EDITOR_NODE_SCENARIO)
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
end
