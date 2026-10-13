require "spec_helper"
require "json"
require "hecks/tools"
require "hecks/tools/site_routes"
require_relative "support/editor_node"

# What a record's own form carries and what the editor refuses before it sends, run under node
# against the stand-in host and a stand-in for the content system: a person who may edit but not
# administer signs in (the members list refuses them; the register of people is read instead), a
# picture and a leaflet are sent to the content system as the person and come back as the address the
# field holds, the text that goes with a record is saved with it (and said plainly when only the
# record was), an address taken twice is refused and never overwritten, and a range that ends before
# it starts is refused before anything is sent.
ENTRY_SITE_MODULES = {
  "site/read.mjs" => <<~JS,
    const paragraph = (part) => ({ type: "paragraph", children: [{ text: part }] });
    export const toNodes = (text) => text.split(/\\n{2,}/).map(paragraph);
  JS
  "site/show.mjs" => <<~JS
    const inner = (node) => node.children.map((child) => child.text).join("");
    export const toHtml = (nodes) => nodes.map((node) => `<p>${inner(node)}</p>`).join("");
  JS
}.freeze

ENTRY_SCENARIO = <<~JS.freeze
  import { accountToken } from "@hecks/client";
  import { mkdirSync, writeFileSync } from "node:fs";
  import { createApp } from "./editor/src/app.ts";
  import { SCHEMA } from "./editor/src/schema.ts";
  import { standInHost } from "./host.mjs";

  const SECRET = "scenario-secret";
  const now = 1_800_000_000;
  const v = (value) => ({ value });
  const instances = {
    "Orchard::Member#ed@example.org": { email: v("ed@example.org"), role: v("Editor") },
    "Orchard::Member#boss@example.org": { email: v("boss@example.org"), role: v("Admin") },
    "Orchard::Member#guest@example.org": { email: v("guest@example.org"), role: v("Viewer") },
    "Orchard::Tree#pear": { slug: v("pear"), name: v("Old Pear"), pickings: [] },
    "Orchard::Tree#plum": { slug: v("plum"), name: v("Plum"), pickings: [] },
    "Orchard::Note#tree.plum.note": { slug: v("tree.plum.note"), kind: v("tree"), address: v("plum"), text: v("Sweet."), written_at: v(1_700_000_000) },
  };
  const host = standInHost(SCHEMA, { instances });
  mkdirSync(`${import.meta.dirname}/editor/dist`, { recursive: true });
  writeFileSync(`${import.meta.dirname}/editor/dist/editor.css`, "body { margin: 0; }\\n");
  writeFileSync(`${import.meta.dirname}/editor/dist/editor.js`, "export {};\\n");

  const known = new Set(["ed@example.org", "boss@example.org", "guest@example.org"]);
  const accounts = [];
  const cms = [];
  let cmsKeeps = true;
  const fetchOf = async (url, init = {}) => {
    const where = new URL(url);
    if (where.host === "cms.test") {
      cms.push({ method: init.method ?? "GET", path: where.pathname, cookie: init.headers?.Cookie ?? null, fields: init.body ? Object.fromEntries([...init.body.entries()].map(([k, f]) => [k, typeof f === "string" ? f : { name: f.name, type: f.type, size: f.size }])) : null });
      if (where.pathname === "/cms/api/sso") return new Response(null, { status: 302, headers: { "set-cookie": "payload-token=abc123; Path=/; HttpOnly" } });
      if (!cmsKeeps) return new Response(JSON.stringify({ errors: [{ message: "The following field is invalid: file" }] }), { status: 400 });
      const name = init.body.get("file").name;
      return new Response(JSON.stringify({ doc: { filename: name, url: `/cms/api/x/file/${name}` } }), { status: 201 });
    }
    if (where.pathname === "/members") return new Response("{}", { status: 403 });
    if (where.pathname === "/accounts/me") {
      const email = init.headers.Cookie.split("=")[1] ? JSON.parse(Buffer.from(init.headers.Cookie.split("=")[1].split(".")[0], "base64url")).email : "";
      accounts.push(email);
      return known.has(email) ? new Response(JSON.stringify({ email }), { status: 200 }) : new Response("{}", { status: 401 });
    }
    return host.fetch(url, init);
  };
  const app = createApp({ fetch: fetchOf, secret: SECRET, url: "http://host.test", cms: "http://cms.test", now: () => now * 1000 });
  const form = { "Content-Type": "application/x-www-form-urlencoded", Origin: "http://site.test" };
  const call = (path, init = {}) => app(new Request(`http://site.test${path}`, init));
  const tokenOf = (email) => accountToken(SECRET, email, 60, { now: () => now * 1000 });
  const cookieOf = async (email) => (await call(`/editor/api/sso?token=${tokenOf(email)}`)).headers.get("set-cookie")?.split(";")[0] ?? null;
  const out = {};

  out.signIn = {};
  for (const email of ["ed@example.org", "boss@example.org", "guest@example.org", "stranger@example.org"]) {
    const res = await call(`/editor/api/sso?token=${tokenOf(email)}`);
    out.signIn[email] = { status: res.status, text: res.status === 302 ? "" : await res.text() };
  }
  const entered = await call("/editor/Tree", { headers: { cookie: `orchard_session=${tokenOf("ed@example.org")}` } });
  out.entered = { status: entered.status, location: entered.headers.get("location"), cookie: Boolean(entered.headers.get("set-cookie")) };
  const refusedEntry = await call("/editor", { headers: { cookie: `orchard_session=${tokenOf("stranger@example.org")}` } });
  out.refusedEntry = { status: refusedEntry.status, text: await refusedEntry.text() };

  const cookie = await cookieOf("ed@example.org");
  const admin = (path, init = {}) => call(path, { ...init, headers: { cookie, ...(init.headers ?? {}) } });
  const post = (body) => ({ method: "POST", body, headers: form });
  const sentVerbs = () => host.sent.filter((one) => one.verb).map((one) => ({ verb: one.verb, to: one.to, with: one.with, role: one.role }));

  out.home = await (await admin("/editor")).text();
  out.newTree = await (await admin("/editor/Tree/new/Plant")).text();
  out.revisePlum = await (await admin("/editor/Tree/id/plum/Revise")).text();

  const upload = async (collection, bytes, { alt = "A tree", filename = "my tree.png", type = "image/png" } = {}) => {
    const body = new FormData();
    if (alt !== null) body.set("alt", alt);
    if (bytes) body.set("file", new Blob([bytes], { type }), filename);
    const res = await admin(`/editor/upload/${collection}`, { method: "POST", body, headers: { Origin: "http://site.test" } });
    return { status: res.status, body: await res.json() };
  };
  const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(40)]);
  const pdf = Buffer.from("%PDF-1.4\\n%%EOF\\n");
  out.uploadPicture = await upload("media", png);
  out.cmsCalls = structuredClone(cms);
  cms.length = 0;
  out.uploadLeaflet = await upload("documents", pdf, { alt: "Pruning leaflet", filename: "../pruning guide.pdf", type: "application/pdf" });
  out.uploadNoAlt = await upload("media", png, { alt: "  " });
  out.uploadNotPicture = await upload("media", Buffer.from("hello, not a picture"));
  out.uploadPdfAsPicture = await upload("media", pdf, { type: "image/png" });
  out.uploadPictureAsPdf = await upload("documents", png, { alt: "x", filename: "a.pdf", type: "application/pdf" });
  out.uploadUnknown = await upload("secrets", png);
  out.uploadNoFile = await upload("media", null);
  out.uploadTooBig = await upload("media", Buffer.concat([png, Buffer.alloc(6 * 1024 * 1024)]));
  cmsKeeps = false;
  out.uploadCmsRefuses = await upload("media", png);
  cmsKeeps = true;
  const strangerCookie = null;
  out.uploadSignedOut = (await call("/editor/upload/media", { method: "POST", body: new FormData(), headers: { Origin: "http://site.test" } })).status;

  host.sent.length = 0;
  const made = await admin("/editor/Tree/new/Plant", post("name.value=Fig+Tree&slug.value=&starts_on.value=2026-08-01T00%3A00&ends_on.value=2026-09-01T00%3A00&__text.0=Eat+%2A%2Aripe%2A%2A+figs."));
  out.made = { status: made.status, location: made.headers.get("location"), sent: sentVerbs() };

  host.sent.length = 0;
  const same = await admin("/editor/Tree/id/plum/Revise", post("name.value=Plum&__text.0=Sweet."));
  out.sameText = { status: same.status, sent: sentVerbs() };

  host.sent.length = 0;
  const changed = await admin("/editor/Tree/id/plum/Revise", post("name.value=Plum&__text.0=Sweet+and+sharp."));
  out.changedText = { status: changed.status, sent: sentVerbs(), note: instances["Orchard::Note#tree.plum.note"].text };

  host.sent.length = 0;
  const twice = await admin("/editor/Tree/new/Plant", post("name.value=Another+Pear&slug.value=pear&__text.0=Never+written"));
  out.duplicate = { status: twice.status, html: await twice.text(), sent: sentVerbs(), kept: instances["Orchard::Tree#pear"].name };

  host.sent.length = 0;
  const backwards = await admin("/editor/Tree/new/Plant", post("name.value=Quince&starts_on.value=2026-09-01T00%3A00&ends_on.value=2026-08-01T00%3A00"));
  out.backwards = { status: backwards.status, html: await backwards.text(), sent: sentVerbs() };
  const rows = await admin("/editor/Tree/new/Plant", post("name.value=Quince&pickings.0.title=First&pickings.0.starts_on=2026-09-01T00%3A00&pickings.0.ends_on=2026-08-30T00%3A00"));
  out.backwardsRow = { status: rows.status, html: await rows.text(), sent: sentVerbs() };
  const fine = await admin("/editor/Tree/new/Plant", post("name.value=Quince&pickings.0.title=First&pickings.0.starts_on=2026-09-01T00%3A00&pickings.0.ends_on=2026-09-01T00%3A00"));
  out.sameInstant = { status: fine.status };

  host.sent.length = 0;
  host.refuseNext("Write", { kind: "InvariantViolation", error: "NoteText invariant violated \\u2014 a note is at most 10 characters (given {\\"value\\":\\"x\\"})" });
  const partial = await admin("/editor/Tree/new/Plant", post("name.value=Lemon&slug.value=&__text.0=A+very+long+note+indeed"));
  out.partial = { status: partial.status, html: await partial.text(), kept: Boolean(instances["Orchard::Tree#lemon"]), noteKept: Boolean(instances["Orchard::Note#tree.lemon.note"]) };

  const site = await import("./editor/src/browser/markdown_site.js");
  out.preview = { available: site.available, html: site.read("one\\n\\ntwo") };
  const { buttons } = await import("./editor/src/browser/markdown.js");
  const act = (id, text, start = 0, end = text.length) => {
    const found = buttons().find((one) => one.id === id).act(text, start, end);
    return { text: found.text, selected: found.text.slice(found.start, found.end) };
  };
  out.toolbar = {
    ids: buttons().map((one) => one.id),
    bold: act("bold", "word"),
    unbold: act("bold", "**word**", 2, 6),
    italic: act("italic", "word"),
    h2: act("h2", "Title"),
    h2Again: act("h2", "## Title"),
    h1Over: act("h1", "## Title"),
    bullets: act("bullets", "a\\nb"),
    numbers: act("numbers", "a"),
    indent: act("indent", "a\\nb"),
    outdent: act("outdent", "    a"),
    link: act("link", "see here", 4, 8),
    lineBreak: act("break", "ab", 1, 1),
    literal: act("literal", "a*b", 1, 2),
  };
  console.log(JSON.stringify(out));
JS

RSpec.describe "the generated editor's entry, uploads, texts and refusals, run by node" do
  let(:project) { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/editor_entry") }

  def files
    projected = Hecks::Tools::SiteRoutes.projection(project, out: "/work/out", editor: "/work/editor")
    projected.select { |path, _| path.start_with?("/work/editor/") }.transform_keys { |path| path.delete_prefix("/work/editor/") }
  end

  def run
    host = File.read(File.join(InMemoryDomain::ROOT, "spec/support/editor_stand_in_host.mjs"))
    @run ||= EditorNode.run(files, ENTRY_SCENARIO, extra: { "host.mjs" => host }.merge(ENTRY_SITE_MODULES))
  end

  def result(key) = run.fetch(key)

  describe "signing in", if: EditorNode.available? do
    it "admits a person who holds an editor role although the host's members list refuses them", :aggregate_failures do
      expect(result("signIn").fetch("ed@example.org").fetch("status")).to eq(302)
      expect(result("signIn").fetch("boss@example.org").fetch("status")).to eq(302)
    end

    it "refuses, in words, a person the register does not hold or whose role is not an editor's", :aggregate_failures do
      expect(result("signIn").fetch("stranger@example.org")).to include("status" => 403)
      expect(result("signIn").fetch("guest@example.org").fetch("text")).to include("not allowed to edit")
    end

    it "starts a session from the site's own session for an admitted person, and says no to another", :aggregate_failures do
      expect(result("entered")).to eq("status" => 303, "location" => "/editor/Tree", "cookie" => true)
      expect(result("refusedEntry")).to include("status" => 403)
      expect(result("refusedEntry").fetch("text")).to include("stranger@example.org", "not allowed to edit")
    end
  end

  describe "pictures and files", if: EditorNode.available? do
    it "draws the address field of an upload with the way to choose, describe and send a file", :aggregate_failures do
      html = result("newTree")

      expect(html).to include('data-upload data-endpoint="/editor/upload/media" data-accept="image"')
      expect(html).to include('data-upload data-endpoint="/editor/upload/documents" data-accept="pdf"')
    end

    it "answers a picture with the address the field holds", :aggregate_failures do
      body = { "address" => "/cms/api/media/file/my-tree.png", "alt" => "A tree", "filename" => "my-tree.png",
               "mime" => "image/png" }

      expect(result("uploadPicture")).to eq("status" => 201, "body" => body)
    end

    it "sends it to the content system as the person, with the description kept there", :aggregate_failures do
      calls = result("cmsCalls")
      sent = calls.last.fetch("fields")

      expect(calls.map { |call| call.values_at("method", "path") }).to eq([["GET", "/cms/api/sso"], ["POST", "/cms/api/media"]])
      expect(calls.last).to include("cookie" => "payload-token=abc123")
      expect(sent).to include("_payload" => { "alt" => "A tree" }.to_json, "file" => include("type" => "image/png"))
    end

    it "keeps a file under a name made of letters, digits, dot, dash and underscore", :aggregate_failures do
      leaflet = result("uploadLeaflet").fetch("body")
      expect(leaflet).to include("address" => "/cms/api/documents/file/pruning-guide.pdf", "mime" => "application/pdf")
    end

    it "refuses what is not what the field takes, by the file's own bytes, with the words to show", :aggregate_failures do
      expect(result("uploadNoAlt")).to eq("status" => 422, "body" => { "error" => "Describe the picture before adding it." })
      expect(result("uploadNotPicture")).to include("status" => 415)
      expect(result("uploadPdfAsPicture")).to include("status" => 415)
      expect(result("uploadPictureAsPdf").fetch("body").fetch("error")).to eq("Only a PDF file can be added here.")
    end

    it "refuses a collection no field uploads to, a missing file and one that is too large", :aggregate_failures do
      expect(result("uploadUnknown")).to include("status" => 404)
      expect(result("uploadNoFile")).to include("status" => 400)
      expect(result("uploadTooBig")).to include("status" => 413)
    end

    it "passes on the content system's own refusal, and requires a session", :aggregate_failures do
      expect(result("uploadCmsRefuses")).to eq("status" => 422, "body" => { "error" => "The following field is invalid: file" })
      expect(result("uploadSignedOut")).to eq(403)
    end
  end

  describe "the text that goes with a record", if: EditorNode.available? do
    it "is one box on the record's form: a Markdown field with the preview and a note", :aggregate_failures do
      html = result("newTree")

      expect(html).to include('name="__text.0"', "data-markdown-input", "data-markdown-toolbar-slot", "What you can use")
      expect(html).to include(">Note <", "Seen by visitors.")
    end

    it "shows what the companion holds now on the form that edits the record" do
      expect(result("revisePlum")).to match(%r{<textarea[^>]*name="__text\.0"[^>]*>\s*Sweet\.</textarea>})
    end

    it "saves the record and then its text, as the roles each declares" do
      verbs = [["Orchard::Tree.Plant", "Editor"], ["Orchard::Note.Write", "System"]]

      expect(result("made").fetch("sent").map { |one| [one["verb"], one["role"]] }).to eq(verbs)
    end

    it "writes the text under the key made from the record's address, and goes on to the record", :aggregate_failures do
      text = { "value" => "Eat **ripe** figs." }

      written = result("made").fetch("sent").last.fetch("with")

      expect(written).to include("slug" => { "value" => "tree.fig-tree.note" }, "text" => text)
      expect(result("made").fetch("location")).to eq("/editor/Tree/id/fig-tree")
    end

    it "rewrites a text that changed and leaves alone one that did not", :aggregate_failures do
      expect(result("sameText").fetch("sent").map { |one| one["verb"] }).to eq(["Orchard::Tree.Revise"])
      expect(result("changedText").fetch("sent").map { |one| one["verb"] }).to eq(["Orchard::Tree.Revise", "Orchard::Note.Rewrite"])
      expect(result("changedText").fetch("note")).to eq("value" => "Sweet and sharp.")
    end

    it "says plainly that the record was saved and its text was not, and keeps what was typed", :aggregate_failures do
      html = result("partial").fetch("html")

      expect(result("partial")).to include("status" => 422, "kept" => true, "noteKept" => false)
      expect(html).to include("was saved, but its note was not")
      expect(html).to include("A very long note indeed")
    end
  end

  describe "what is refused before it is sent", if: EditorNode.available? do
    it "refuses an address a record already holds, names who holds it and overwrites nothing", :aggregate_failures do
      result("duplicate").then do |found|
        expect(found).to include("status" => 422, "kept" => { "value" => "Old Pear" }, "sent" => [])
        expect(found.fetch("html")).to include("That address is already used by Old Pear.", 'aria-invalid="true"')
      end
    end

    it "refuses a range that ends before it starts, at the top and in a row, before sending", :aggregate_failures do
      expect(result("backwards")).to include("status" => 422, "sent" => [])
      expect(result("backwards").fetch("html")).to include("This ends before it starts.", 'aria-invalid="true"')
      expect(result("backwardsRow")).to include("status" => 422, "sent" => [])
      expect(result("backwardsRow").fetch("html")).to include("Picking 1: This ends before it starts.")
    end

    it "accepts an end that is the same moment as the start" do
      expect(result("sameInstant")).to eq("status" => 303)
    end
  end

  describe "the Markdown field's toolbar and preview", if: EditorNode.available? do
    it "shows what the site's own reader and renderer make of the text" do
      expect(result("preview")).to eq("available" => true, "html" => "<p>one</p><p>two</p>")
    end

    it "has a button for each thing the site understands and nothing else" do
      expect(result("toolbar").fetch("ids")).to eq(%w[h1 h2 h3 h4 bold italic link bullets numbers indent outdent break literal])
    end

    it "wraps and unwraps bold", :aggregate_failures do
      expect(result("toolbar").fetch("bold")).to eq("text" => "**word**", "selected" => "word")
      expect(result("toolbar").fetch("unbold")).to eq("text" => "word", "selected" => "word")
    end

    it "makes a heading, takes it off again and changes its level", :aggregate_failures do
      toolbar = result("toolbar")

      expect(toolbar.fetch("h2").fetch("text")).to eq("## Title")
      expect(toolbar.fetch("h2Again").fetch("text")).to eq("Title")
      expect(toolbar.fetch("h1Over").fetch("text")).to eq("# Title")
    end

    it "makes lists and a list inside a list", :aggregate_failures do
      toolbar = result("toolbar")

      expect(toolbar.fetch("bullets").fetch("text")).to eq("- a\n- b")
      expect(toolbar.fetch("indent").fetch("text")).to eq("    a\n    b")
      expect(toolbar.fetch("outdent").fetch("text")).to eq("a")
    end

    it "makes a link, a line break and a character that shows as itself", :aggregate_failures do
      toolbar = result("toolbar")

      expect(toolbar.fetch("link")).to eq("text" => "see [here](https://)", "selected" => "https://")
      expect(toolbar.fetch("lineBreak").fetch("text")).to eq("a  \nb")
      expect(toolbar.fetch("literal").fetch("text")).to eq("a&#42;b")
    end
  end
end
