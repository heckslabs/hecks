require "spec_helper"
require "cgi"
require "json"
require "hecks/tools"
require "hecks/tools/site_routes"
require_relative "support/editor_node"

# The editor as a person who looks after the pages of a small site uses it, run under node against a
# stand-in host (spec/support/editor_stand_in_host.mjs): hiding a page and putting it back (what the
# page says to visitors, what the gate answers, what the page's own screen says), where each page is
# shown, what a template does not draw, a new page made in one form, what the History says of a long
# text, which buttons a working copy shows, and the order of a page's regions. The neutral project is
# spec/fixtures/site/editor_fixed_pages.
PAGES_NODE_SCENARIO = <<~JS.freeze
  import { accountToken } from "@hecks/client";
  import { mkdirSync, writeFileSync } from "node:fs";
  import { createApp } from "./editor/src/app.ts";
  import { SCHEMA } from "./editor/src/schema.ts";
  import { forgetHidden } from "./editor/src/site.ts";
  import { standInHost } from "./host.mjs";

  const SECRET = "scenario-secret";
  const now = 1_800_000_000;
  const v = (value) => ({ value });
  const words = (...texts) => ({ blocks: texts.map((text) => ({ kind: "paragraph", spans: [{ text, marks: [] }], items: [] })) });
  const leaflet = (slug, title, tags = []) => ({ slug: v(slug), title: v(title), tags: tags.map(v), status: "live" });
  const instances = {
    "Leaflets::NotePage#page:note": { key: v("page:note"), content: { heading: "A note", body: words("Hello, this is the first paragraph of the note."), rows: [] } },
    "Leaflets::ChaptersPage#page:story": { key: v("page:story"), content: { chapters: [{ heading: "One", body: words("One.") }] }, draft_content: { chapters: [{ heading: "One", body: words("One, edited.") }] } },
    "Leaflets::Leaflet#note": leaflet("note", "A note"),
    "Leaflets::Leaflet#story": leaflet("story", "The story"),
    "Leaflets::Leaflet#plain": leaflet("plain", "Plain"),
    "Leaflets::Leaflet#secret": leaflet("secret", "Secret", ["private"]),
    "Pictures::MediaItem#aa.png": { key: v("aa.png"), alt: v("A red door"), mime_type: v("image/png") },
  };
  const host = standInHost(SCHEMA, { instances });
  const sitemap = `<?xml version="1.0"?>\\n<urlset>\\n  <url>\\n    <loc>https://leaflets.example/note</loc>\\n  </url>\\n  <url>\\n    <loc>https://leaflets.example/other</loc>\\n  </url>\\n  <url>\\n    <loc>https://leaflets.example/story/chapters</loc>\\n  </url>\\n</urlset>\\n`;
  const fetcher = async (url, init) => (String(url).startsWith("http://site.invalid/") ? new Response(sitemap, { status: 200 }) : host.fetch(url, init));
  const storage = { put: async () => {}, url: (key) => key, read: async () => null };
  mkdirSync(`${import.meta.dirname}/editor/dist`, { recursive: true });
  writeFileSync(`${import.meta.dirname}/editor/dist/editor.css`, "body { margin: 0; }\\n");
  writeFileSync(`${import.meta.dirname}/editor/dist/editor.js`, "export {};\\n");

  const app = createApp({ fetch: fetcher, secret: SECRET, url: "http://host.test", now: () => now * 1000, storage });
  const form = { "Content-Type": "application/x-www-form-urlencoded", Origin: "http://site.test" };
  const call = (path, init = {}) => app(new Request(`http://site.test${path}`, init));
  const token = accountToken(SECRET, "ed@example.org", 60, { now: () => now * 1000 });
  const cookie = (await call(`/editor/api/sso?token=${token}`)).headers.get("set-cookie").split(";")[0];
  const admin = (path, init = {}) => call(path, { ...init, headers: { cookie, ...(init.headers ?? {}) } });
  const post = (body, extra = {}) => ({ method: "POST", body, headers: { ...form, ...extra } });
  const gate = async (path) => { forgetHidden(); return (await call(`/editor/gate?path=${encodeURIComponent(path)}`)).status; };
  const NOTE = "/editor/Leaflets/NotePage/id/page%3Anote";
  const out = {};

  // Hiding a page and putting it back.
  out.pageBefore = await (await admin(NOTE)).text();
  out.gateBefore = { note: await gate("/note"), other: await gate("/other"), chapters: await gate("/story/chapters"), trailing: await gate("/note/") };
  host.sent.length = 0;
  const hid = await admin("/editor/Leaflets/Leaflet/id/note/TakeDown", post(`__back=${encodeURIComponent("/editor/Leaflets/NotePage/id/page%3Anote")}`));
  out.hid = { status: hid.status, location: hid.headers.get("location"), sent: host.sent.filter((one) => one.verb).map((one) => ({ verb: one.verb, to: one.to })), state: instances["Leaflets::Leaflet#note"].status };
  out.pageHidden = await (await admin(NOTE)).text();
  out.gateAfter = { note: await gate("/note"), trailing: await gate("/note/"), query: await gate("/note?x=1"), other: await gate("/other"), story: await gate("/story") };
  out.hiddenList = await (await admin("/editor/pages")).text();
  out.wordsKept = JSON.stringify(instances["Leaflets::NotePage#page:note"].content);
  out.askPage = await (await admin("/editor/Leaflets/Leaflet/id/note/PutBack")).text();
  const back = await admin("/editor/Leaflets/Leaflet/id/note/PutBack", post(`__back=${encodeURIComponent("/editor/Leaflets/NotePage/id/page%3Anote")}`));
  out.back = { status: back.status, state: instances["Leaflets::Leaflet#note"].status, gate: await gate("/note") };
  const twice = await admin("/editor/Leaflets/Leaflet/id/note/PutBack", post(""));
  out.putBackTwice = { status: twice.status };

  // The gate says nothing it should not, and a host that cannot answer hides nothing.
  out.gateWithoutPath = (await call("/editor/gate")).status;
  const broken = createApp({ fetch: async () => { throw new Error("down"); }, secret: SECRET, url: "http://host.test", now: () => now * 1000, storage });
  forgetHidden();
  out.gateHostDown = (await broken(new Request("http://site.test/editor/gate?path=/note"))).status;

  // Where each page is shown, and what its template leaves out.
  out.storyDraft = await (await admin("/editor/Leaflets/ChaptersPage/id/page%3Astory/SaveDraft")).text();
  out.noteDraft = await (await admin(`${NOTE}/SaveDraft`)).text();
  out.noteDetail = await (await admin(NOTE)).text();
  out.plainDetail = await (await admin("/editor/Leaflets/Leaflet/id/plain")).text();
  out.secretDetail = await (await admin("/editor/Leaflets/Leaflet/id/secret")).text();
  await admin("/editor/Leaflets/Leaflet/id/plain/TakeDown", post(""));
  out.plainHiddenDetail = await (await admin("/editor/Leaflets/Leaflet/id/plain")).text();

  // The sitemap leaves out a hidden page.
  await admin("/editor/Leaflets/Leaflet/id/note/TakeDown", post(""));
  forgetHidden();
  const map = await call("/editor/sitemap.xml");
  out.sitemap = { status: map.status, type: map.headers.get("content-type"), text: await map.text() };

  // A page made in one form.
  out.newForm = await (await admin("/editor/Leaflets/NotePage/new/Write")).text();
  host.sent.length = 0;
  const fresh = `title.value=Fresh+Note&slug.value=&content.heading=Fresh&content.body.blocks.0.kind=paragraph&content.body.blocks.0.spans.0.text=Hello`;
  const made = await admin("/editor/Leaflets/NotePage/new/Write", post(fresh));
  out.made = { status: made.status, location: made.headers.get("location"), sent: host.sent.filter((one) => one.verb).map((one) => one.verb), leaflet: instances["Leaflets::Leaflet#fresh-note"], page: instances["Leaflets::NotePage#page:fresh-note"]?.key };
  const again = await admin("/editor/Leaflets/NotePage/new/Write", post(fresh));
  out.madeTwice = { status: again.status, html: await again.text() };
  const named = await admin("/editor/Leaflets/NotePage/new/Write", post("title.value=Other&slug.value=My+Own&content.body.blocks.0.kind=paragraph&content.body.blocks.0.spans.0.text=Hi"));
  out.named = { status: named.status, location: named.headers.get("location") };

  // What the History says of a long text.
  const edit = `content.heading=A+note&content.body.blocks.0.kind=paragraph&content.body.blocks.0.spans.0.text=${encodeURIComponent("Hello, this is the changed first paragraph of the note, now longer than before.")}`;
  await admin(`${NOTE}/Revise`, post(edit));
  out.afterEdit = await (await admin(NOTE)).text();

  // A working copy offers to publish only when it holds one.
  host.sent.length = 0;
  await admin(`${NOTE}/SaveDraft`, post(edit.replaceAll("content.", "draft_content.")));
  out.noteDraftSaved = await (await admin(`${NOTE}/SaveDraft`)).text();

  console.log(JSON.stringify(out));
JS

NOTE_PAGE = "/editor/Leaflets/NotePage/id/page%3Anote".freeze

RSpec.describe "the editor for the pages of a site, run by node", if: EditorNode.available? do
  let(:project) { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/editor_fixed_pages") }
  let(:files) do
    all = Hecks::Tools::SiteRoutes.projection(project, out: "/work/out", editor: "/work/editor")
    all.select { |path, _| path.start_with?("/work/editor/") }.transform_keys { |path| path.delete_prefix("/work/editor/") }
  end

  let(:stand_in) { File.read(File.join(InMemoryDomain::ROOT, "spec/support/editor_stand_in_host.mjs")) }

  def result(key) = (@results ||= EditorNode.run(files, PAGES_NODE_SCENARIO, extra: { "host.mjs" => stand_in })).fetch(key)

  def text_of(html) = CGI.unescapeHTML(html.gsub(/<[^>]+>/, " ")).gsub(/\s+/, " ")

  describe "hiding a page" do
    it "offers Hide page on the page itself, asking first and saying what visitors will see", :aggregate_failures do
      html = result("pageBefore")

      expect(html).to include("Hide page", 'data-confirm="confirm-TakeDown"')
      expect(text_of(html)).to include('Visitors will see "page not found" for this page.', "Its words are kept")
      expect(html).to include("Showing")
    end

    it "runs the page record's own command, sends the person back to the page, and keeps the words", :aggregate_failures do
      expect(result("hid")).to include("status" => 303, "location" => NOTE_PAGE, "state" => "down")
      expect(result("hid")["sent"]).to eq([{ "verb" => "Leaflets::Leaflet.TakeDown", "to" => "note" }])
      expect(result("wordsKept")).to include("Hello, this is the first paragraph")
    end

    it "says on the page that it is hidden and offers it back, without a link to the site", :aggregate_failures do
      html = result("pageHidden")

      expect(text_of(html)).to include("Hidden from the site", "Visitors see \"page not found\"", "Put page back")
      expect(html).not_to include('href="/note"')
    end

    it "words the state in the list as Hidden", :aggregate_failures do
      expect(text_of(result("hiddenList"))).to include("Hidden")
      expect(text_of(result("hiddenList"))).to include("Showing")
    end

    it "asks no more than the gate: a hidden page's every address is not found, nothing else", :aggregate_failures do
      expect(result("gateBefore")).to eq("note" => 204, "other" => 204, "chapters" => 204, "trailing" => 204)
      expect(result("gateAfter")).to include("note" => 404, "trailing" => 404, "query" => 404, "other" => 204, "story" => 204)
    end

    it "answers every address a page has, and a page put back is shown again", :aggregate_failures do
      expect(result("back")).to include("status" => 303, "state" => "live", "gate" => 204)
    end

    it "shows nothing hidden when the host cannot answer, and answers an empty question as shown", :aggregate_failures do
      expect(result("gateHostDown")).to eq(204)
      expect(result("gateWithoutPath")).to eq(204)
    end

    it "has the no-script question for a page that has to be asked", :aggregate_failures do
      expect(text_of(result("askPage"))).to include("Put page back", "Visitors will see the page again.")
    end
  end

  describe "where a page is shown" do
    it "links a page to its address, and a record to its template unless a rule says it has no page", :aggregate_failures do
      expect(result("noteDetail")).to include('href="/note" target="_blank"', "Preview")
      expect(result("plainDetail")).to include('href="/leaflets/plain"')
      expect(result("secretDetail")).not_to include('href="/leaflets/secret"')
      expect(result("plainHiddenDetail")).not_to include('href="/leaflets/plain"')
    end

    it "leaves a hidden page's entry out of the site's sitemap, and keeps the rest as it was", :aggregate_failures do
      map = result("sitemap")

      expect(map).to include("status" => 200)
      expect(map["type"]).to include("application/xml")
      expect(map["text"]).to include("https://leaflets.example/other", "https://leaflets.example/story/chapters")
      expect(map["text"]).not_to include("https://leaflets.example/note")
    end

    it "says what the site's template does not draw of a page, from the rows", :aggregate_failures do
      expect(text_of(result("storyDraft"))).to include("The public site does not show the parts of a chapter on this page yet.")
      expect(text_of(result("noteDraft"))).not_to include("The public site does not show")
    end
  end

  describe "a new page" do
    it "is one form: its title and address with its words, the key made from the address", :aggregate_failures do
      html = result("newForm")

      expect(html).to include('name="title.value"', 'name="slug.value"', 'name="content.heading"')
      expect(html).not_to include('name="key.value"')
      expect(text_of(html)).to include("Page title", "Address")
    end

    it "makes the page's record and then the page, under the key the address gives", :aggregate_failures do
      made = result("made")

      expect(made).to include("status" => 303, "location" => "/editor/Leaflets/NotePage/id/page%3Afresh-note")
      expect(made["sent"]).to eq(%w[Leaflets::Leaflet.Create Leaflets::NotePage.Write])
      expect(made["leaflet"]).to include("title" => { "value" => "Fresh Note" }, "status" => "live")
      expect(made["page"]).to eq("value" => "page:fresh-note")
    end

    it "refuses an address that is taken, on the address, and uses the one typed when there is one", :aggregate_failures do
      expect(result("madeTwice")["status"]).to eq(422)
      expect(text_of(result("madeTwice")["html"])).to include("That address is already used by Fresh Note.")
      expect(result("named")).to include("status" => 303, "location" => "/editor/Leaflets/NotePage/id/page%3Amy-own")
    end

    it "folds the slots the rows keep behind More options inside the page, not only at the form's top" do
      html = result("newForm")

      expect(html.index("More options")).to be < html.index("Summary")
    end
  end

  describe "the History of a page" do
    it "says what changed in a long text: which slot, and its first words before and after", :aggregate_failures do
      html = text_of(result("afterEdit"))

      expect(html).to include("rich text edited", "is the first paragraph", "is the changed first")
      expect(html).not_to include("was changed, now changed")
    end
  end

  describe "a working copy" do
    it "offers neither Publish draft nor Discard draft until a draft is saved", :aggregate_failures do
      expect(result("noteDraft")).to include("hidden data-draft-publish>Publish draft", "hidden data-draft-discard>Discard draft")
      expect(result("storyDraft")).not_to include("hidden data-draft-publish>Publish draft")
      expect(result("noteDraftSaved")).not_to include("hidden data-draft-publish>Publish draft")
    end
  end

  describe "the page's regions" do
    it "puts the status and actions first in the document, as they are first on a narrow screen", :aggregate_failures do
      html = result("noteDetail")

      expect(html.index('aria-label="Status and actions"')).to be < html.index('<section class="min-w-0 border')
      expect(html).to include("lg:order-last")
    end
  end
end
