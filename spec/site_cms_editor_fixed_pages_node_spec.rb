require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "hecks/tools"
require "hecks/tools/site_routes"
require_relative "support/editor_node"

# The editor working on pages of a fixed structure, run under node against a stand-in host
# (spec/support/editor_stand_in_host.mjs): the form of a working copy that is a value object, a picture
# slot and a writing box outside a block list, repeated groups that hold groups, how a form is turned
# back into the command's arguments, and which part of the page a refusal is about. The pure halves
# (the encoding and the mapping of a refusal) are run over tables.
FIXED_PAGES_NODE_SCENARIO = <<~JS.freeze
  import { accountToken } from "@hecks/client";
  import { mkdirSync, writeFileSync } from "node:fs";
  import { createApp } from "./editor/src/app.ts";
  import { SCHEMA } from "./editor/src/schema.ts";
  import { commandArguments, parseForm } from "./editor/src/ui/input.ts";
  import { heavy, problemsOf, summaryOf } from "./editor/src/ui/block_list.js";
  import { standInHost } from "./host.mjs";

  const SECRET = "scenario-secret";
  const now = 1_800_000_000;
  const v = (value) => ({ value });
  const words = (...texts) => ({ blocks: texts.map((text) => ({ kind: "paragraph", spans: [{ text, marks: [] }], items: [] })) });
  const chapters = Array.from({ length: 12 }, (_, at) => ({
    heading: `Chapter ${at + 1}`,
    body: words(`Words of chapter ${at + 1}.`),
    parts: at % 3 === 0 ? [{ heading: "Part A", body: words("A.") }, { heading: "Part B", body: words("B.") }] : [],
    ...(at % 4 === 0 ? { band: { media_ref: "aa.png", alt: "A red door", align: v("center") } } : {}),
  }));
  const hero = { heading: "Opening", picture: { media_ref: "aa.png", alt: "A red door" } };
  const instances = {
    "Leaflets::ChaptersPage#page:story": { key: v("page:story"), content: { hero, chapters }, draft_content: { hero, chapters: chapters.slice(0, 2) } },
    "Leaflets::ChaptersPage#page:fresh": { key: v("page:fresh"), content: { chapters: chapters.slice(0, 3) } },
    "Leaflets::NotePage#page:note": { key: v("page:note"), content: { heading: "A note", summary: "Short.\\nTwo lines.", body: words("Hello."), rows: [{ title: "R1", cells: [{ text: "a" }, { text: "b" }] }] } },
    "Leaflets::GalleryPage#page:pics": { key: v("page:pics"), content: { heading: "Pictures", photos: [{ media_ref: "aa.png", alt: "Red door" }, { media_ref: "bb.png", alt: "Blue gate" }] } },
    "Leaflets::RosterPage#page:team": { key: v("page:team"), people: [{ name: "Ann", role: "Lead", about: "Ann leads.", portrait: { media_ref: "aa.png", alt: "Ann smiling" } }], draft_people: [{ name: "Ben" }] },
    "Pictures::MediaItem#aa.png": { key: v("aa.png"), alt: v("A red door"), mime_type: v("image/png") },
  };
  const host = standInHost(SCHEMA, { instances });
  const storage = { put: async () => {}, url: (key) => key, read: async () => null };
  mkdirSync(`${import.meta.dirname}/editor/dist`, { recursive: true });
  writeFileSync(`${import.meta.dirname}/editor/dist/editor.css`, "body { margin: 0; }\\n");
  writeFileSync(`${import.meta.dirname}/editor/dist/editor.js`, "export {};\\n");

  const app = createApp({ fetch: host.fetch, secret: SECRET, url: "http://host.test", now: () => now * 1000, storage });
  const form = { "Content-Type": "application/x-www-form-urlencoded", Origin: "http://site.test" };
  const call = (path, init = {}) => app(new Request(`http://site.test${path}`, init));
  const token = accountToken(SECRET, "ed@example.org", 60, { now: () => now * 1000 });
  const cookie = (await call(`/editor/api/sso?token=${token}`)).headers.get("set-cookie").split(";")[0];
  const admin = (path, init = {}) => call(path, { ...init, headers: { cookie, ...(init.headers ?? {}) } });
  const post = (body, extra = {}) => ({ method: "POST", body, headers: { ...form, ...extra } });
  const STORY = "/editor/Leaflets/ChaptersPage/id/page%3Astory";
  const out = {};

  out.storyDraft = await (await admin(`${STORY}/SaveDraft`)).text();
  out.freshDraft = await (await admin("/editor/Leaflets/ChaptersPage/id/page%3Afresh/SaveDraft")).text();
  out.storyDetail = await (await admin(STORY)).text();
  out.noteDraft = await (await admin("/editor/Leaflets/NotePage/id/page%3Anote/SaveDraft")).text();
  out.galleryDraft = await (await admin("/editor/Leaflets/GalleryPage/id/page%3Apics/SaveDraft")).text();
  out.rosterDraft = await (await admin("/editor/Leaflets/RosterPage/id/page%3Ateam/SaveDraft")).text();
  out.newStory = await (await admin("/editor/Leaflets/ChaptersPage/new/Write")).text();

  const story = SCHEMA.aggregates.find((agg) => agg.name === "ChaptersPage");
  const roster = SCHEMA.aggregates.find((agg) => agg.name === "RosterPage");
  const encode = (agg, body, name = "SaveDraft") => {
    const command = agg.commands.find((candidate) => candidate.name === name);
    return commandArguments(agg, command.attributes, parseForm(body), command.empty ?? []);
  };
  const c = "draft_content";
  out.encoding = {
    whole: encode(story, `${c}.hero.heading=Hi&${c}.hero.picture.media_ref=aa.png&${c}.hero.picture.alt=Door&${c}.chapters.0.heading=One&${c}.chapters.0.band.media_ref=bb.png&${c}.chapters.0.band.alt=Gate&${c}.chapters.0.band.align.value=center&${c}.chapters.1.verse.body.blocks.0.kind=paragraph&${c}.chapters.1.verse.body.blocks.0.spans.0.text=Verse&${c}.chapters.1.parts.0.heading=P&${c}.chapters.1.parts.0.body.blocks.0.kind=paragraph&${c}.chapters.1.parts.0.body.blocks.0.spans.0.text=Part`),
    blankGroupsLeftOut: encode(story, `${c}.hero.heading=&${c}.hero.picture.media_ref=&${c}.hero.picture.alt=&${c}.chapters.0.heading=One&${c}.chapters.0.verse.heading=&${c}.chapters.0.band.media_ref=&${c}.chapters.0.band.alt=&${c}.chapters.0.band.align.value=`),
    halfFilledGroupKept: encode(story, `${c}.chapters.0.heading=One&${c}.chapters.0.band.media_ref=bb.png&${c}.chapters.0.band.alt=`),
    blankMemberDropped: encode(story, `${c}.chapters.0.heading=&${c}.chapters.0.parts.0.heading=&${c}.chapters.1.heading=Two`),
    blankPartDropped: encode(story, `${c}.chapters.0.heading=One&${c}.chapters.0.parts.0.heading=&${c}.chapters.0.parts.1.heading=Kept`),
    order: encode(story, `${c}.chapters.1.heading=Second&${c}.chapters.0.heading=First&${c}.chapters.2.heading=Third`).draft_content.chapters.map((one) => one.heading),
    noChapters: encode(story, `${c}.hero.heading=Hi`),
    partsOrder: encode(story, `${c}.chapters.0.heading=One&${c}.chapters.0.parts.1.heading=B&${c}.chapters.0.parts.1.body.blocks.0.kind=paragraph&${c}.chapters.0.parts.1.body.blocks.0.spans.0.text=b&${c}.chapters.0.parts.0.heading=A&${c}.chapters.0.parts.0.body.blocks.0.kind=paragraph&${c}.chapters.0.parts.0.body.blocks.0.spans.0.text=a`).draft_content.chapters[0].parts.map((part) => part.heading),
    publishClears: encode(story, "", "PublishDraft"),
    rosterPublishClears: encode(roster, "", "PublishDraft"),
    rosterDiscardClears: encode(roster, "", "DiscardDraft"),
    rosterList: encode(roster, "draft_people.0.name=Ann&draft_people.0.about=Line%0D%0ATwo&draft_people.0.portrait.media_ref=&draft_people.0.portrait.alt=&draft_people.1.name="),
    crlf: encode(roster, "draft_people.0.name=Ann&draft_people.0.about=One%0D%0ATwo").draft_people[0].about,
  };

  const attrs = story.commands.find((command) => command.name === "SaveDraft").attributes;
  const refused = (error, args) => problemsOf(error, attrs, args, story.valueObjects).map((problem) => ({ path: problem.path, name: problem.name, slots: problem.slots, message: problem.message }));
  const band = { media_ref: "bb.png", alt: "" };
  const given = (value) => JSON.stringify(value);
  const base = (list) => ({ draft_content: { chapters: list } });
  out.refusals = {
    bandNotDescribed: refused(`Band invariant violated — a band is described (given ${given({ ...band, caption: null, align: null })})`, base([{ heading: "One" }, { heading: "Two", band }, { heading: "Three", band: { media_ref: "cc.png", alt: "" } }])),
    onlyOneOfItsType: refused("Verse invariant violated — a verse has writing", base([{ heading: "One" }, { verse: { heading: "V", body: { blocks: [] } } }])),
    ambiguous: refused("Part invariant violated — a part has a heading", base([{ parts: [{ heading: "", body: { blocks: [] } }] }, { parts: [{ heading: "", body: { blocks: [] } }] }])),
    chapterSaysNothing: refused(`Chapter invariant violated — a chapter says something (given ${given({ verse: null, band: null, heading: null, body: null, parts: [] })})`, base([{ heading: "One" }, { parts: [] }])),
    partOfAChapter: refused(`Part invariant violated — a part has writing (given ${given({ heading: "B", body: { blocks: [] } })})`, base([{ heading: "One", parts: [{ heading: "A", body: words("a") }, { heading: "B", body: { blocks: [] } }] }])),
    contentRule: refused("ChaptersContent invariant violated — a page has at least one chapter", { draft_content: { chapters: [] } }),
    heroPicture: refused(`Picture invariant violated — a picture is described (given ${given({ media_ref: "aa.png", alt: "", caption: null })})`, { draft_content: { hero: { heading: "H", picture: { media_ref: "aa.png", alt: "" } }, chapters: [{ heading: "One" }] } }),
    notAboutAValue: refused("Governance refused — not allowed", base([{ heading: "One" }])),
  };

  const note = SCHEMA.aggregates.find((agg) => agg.name === "NotePage");
  out.heavy = { chapters: heavy(story.valueObjects, "Chapter"), part: heavy(story.valueObjects, "Part"), hero: heavy(story.valueObjects, "Hero"), band: heavy(story.valueObjects, "Band"), key: heavy(story.valueObjects, "LeafletKey"), row: heavy(note.valueObjects, "Row"), cell: heavy(note.valueObjects, "Cell") };
  const gallery = SCHEMA.aggregates.find((agg) => agg.name === "GalleryPage");
  const photos = gallery.valueObjects.GalleryContent.find((part) => part.name === "photos");
  out.summaries = [
    summaryOf({ discriminator: "", kinds: [] }, gallery.valueObjects.Picture, { media_ref: "aa.png", alt: "Red door", caption: "Cap" }, photos.picture),
    summaryOf({ discriminator: "", kinds: [] }, gallery.valueObjects.Picture, { media_ref: "aa.png", alt: "", caption: "Cap" }, photos.picture),
    summaryOf({ discriminator: "", kinds: [] }, story.valueObjects.Chapter, { heading: "One", parts: [] }),
    summaryOf({ discriminator: "", kinds: [] }, story.valueObjects.Chapter, { parts: [{ heading: "A" }, { heading: "B" }] }),
  ];

  host.sent.length = 0;
  const body = `${c}.chapters.0.heading=Moved&${c}.chapters.1.heading=Then&__back=%2Feditor`;
  const saved = await admin(`${STORY}/SaveDraft`, post(body));
  out.saved = { status: saved.status, location: saved.headers.get("location"), sent: host.sent.filter((one) => one.verb).map((one) => ({ verb: one.verb, to: one.to, with: one.with })) };
  out.afterSave = instances["Leaflets::ChaptersPage#page:story"].draft_content.chapters.map((chapter) => chapter.heading);

  host.sent.length = 0;
  const auto = await admin(`${STORY}/SaveDraft`, post(`${c}.chapters.0.heading=Auto`, { "x-editor-autosave": "1" }));
  out.autosaved = { status: auto.status, text: await auto.text(), sent: host.sent.filter((one) => one.verb).map((one) => one.verb) };
  out.liveAfterAutosave = instances["Leaflets::ChaptersPage#page:story"].content.chapters.length;

  const violation = (given) => ({ kind: "InvariantViolation", error: `Band invariant violated — a band is described (given ${JSON.stringify(given)})` });
  host.refuseNext("SaveDraft", violation({ media_ref: "bb.png", alt: "", caption: null, align: null }));
  const refusedAuto = await admin(`${STORY}/SaveDraft`, post(`${c}.chapters.0.heading=One&${c}.chapters.0.band.media_ref=bb.png&${c}.chapters.0.band.alt=`, { "x-editor-autosave": "1" }));
  out.autosaveRefused = { status: refusedAuto.status, text: await refusedAuto.text(), problems: JSON.parse(decodeURIComponent(refusedAuto.headers.get("x-editor-problems") ?? "null")) };

  host.refuseNext("SaveDraft", violation({ media_ref: "bb.png", alt: "", caption: null, align: null }));
  const refusedPage = await admin(`${STORY}/SaveDraft`, post(`${c}.hero.heading=Kept&${c}.chapters.0.heading=One&${c}.chapters.0.band.media_ref=bb.png&${c}.chapters.0.band.alt=&${c}.chapters.1.heading=Two&${c}.chapters.1.parts.0.heading=P&${c}.chapters.1.parts.0.body.blocks.0.kind=paragraph&${c}.chapters.1.parts.0.body.blocks.0.spans.0.text=Kept`));
  out.refusedPage = { status: refusedPage.status, html: await refusedPage.text() };

  host.sent.length = 0;
  await admin(`${STORY}/PublishDraft`, post(""));
  out.published = { live: instances["Leaflets::ChaptersPage#page:story"].content.chapters.length, draft: "draft_content" in instances["Leaflets::ChaptersPage#page:story"], sent: host.sent.filter((one) => one.verb).map((one) => ({ verb: one.verb, with: one.with })) };

  host.sent.length = 0;
  await admin("/editor/Leaflets/RosterPage/id/page%3Ateam/DiscardDraft", post(""));
  out.discarded = { draft: "draft_people" in instances["Leaflets::RosterPage#page:team"], live: instances["Leaflets::RosterPage#page:team"].people.length, sent: host.sent.filter((one) => one.verb).map((one) => ({ verb: one.verb, with: one.with })) };

  console.log(JSON.stringify(out));
JS

RSpec.describe "the generated fixed-structure page editor, run by node" do
  let(:project) { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/editor_fixed_pages") }

  def files
    projected = Hecks::Tools::SiteRoutes.projection(project, out: "/work/out", editor: "/work/editor")
    projected.select { |path, _| path.start_with?("/work/editor/") }.transform_keys { |path| path.delete_prefix("/work/editor/") }
  end

  def run
    host = File.read(File.join(InMemoryDomain::ROOT, "spec/support/editor_stand_in_host.mjs"))
    @run ||= EditorNode.run(files, FIXED_PAGES_NODE_SCENARIO, extra: { "host.mjs" => host })
  end

  def result(key) = run.fetch(key)

  # The card of the list named `path` that starts at index `index`, up to the next card of its level.
  def card(html, path, index)
    id = "blk-#{path}"
    after = "<li class=\"[^\"]*\" id=\"#{id}-#{index + 1}\"|</ol>\n"
    html[/<li class="[^"]*" id="#{id}-#{index}" data-card.*?(?=#{after})/m]
  end

  def names_in(html) = html.scan(/ name="([a-z_]+\.[a-z_.0-9]+)"/).flatten

  describe "the form of a working copy that is a value object", if: EditorNode.available? do
    it "marks the form as saved as a whole, with the draft's status and the publish and discard buttons", :aggregate_failures do
      html = result("storyDraft")

      expect(html).to include('data-draft="draft_content" data-draft-form', "data-draft-status", "A draft is saved.")
      expect(html).to include('confirm-DiscardDraft">Discard draft</a>', 'confirm-PublishDraft">Publish draft</a>',
                              "data-flush-draft")
    end

    it "starts from the live content when no draft is saved, then says none is", :aggregate_failures do
      html = result("freshDraft")

      expect(html).to include("No draft is saved yet.", 'value="Chapter 1"')
      expect(html).to include('confirm-DiscardDraft" hidden data-draft-discard>Discard draft</a>')
    end

    it "shows the draft, not the live content, when one is saved" do
      html = result("storyDraft")

      expect(html.scan(/data-card data-index="\d+" data-kind=""/).size).to eq(2 + 2)
    end

    it "says on the record's page that changes are not published yet, and shows its content as read-only parts",
       :aggregate_failures do
      html = result("storyDetail")

      expect(html).to include("Changes not published yet", "<ol class=\"grid list-decimal gap-3 pl-6\">", "Chapter 12")
      expect(html).not_to include("&quot;blocks&quot;")
    end

    it "offers the creating command the same form, with the first chapter to add", :aggregate_failures do
      html = result("newStory")

      expect(html).to include("data-block-list", "No chapters yet.", 'name="content.chapters.ZZI0ZZ.heading"')
    end
  end

  describe "repeated groups that hold groups", if: EditorNode.available? do
    let(:html) { result("storyDraft") }

    it "draws a list whose members hold writing, a picture or a list as cards, in order", :aggregate_failures do
      expect(html).to include('data-block-list data-group data-path="draft_content.chapters" data-noun="chapter" data-depth="0"')
      ids = html.scan(/ id="(blk-draft-content-chapters-\d+)" data-card data-index/).flatten

      expect(ids).to eq(%w[blk-draft-content-chapters-0 blk-draft-content-chapters-1])
    end

    it "says the limits the holder's rules give, and carries the most as data", :aggregate_failures do
      expect(html).to include("At least 1 and at most 60.", 'data-max="60"')
      expect(card(html, "draft-content-chapters",
                  0)).to include('data-path="draft_content.chapters.0.parts" data-noun="part" data-max="12"')
    end

    it "gives each card move up, move down and remove buttons that name it, and a live region for what moved",
       :aggregate_failures do
      first = card(html, "draft-content-chapters", 0)

      expect(first).to include('data-action="up"', 'data-action="down"', 'data-action="remove"',
                               'aria-label="Move up chapter 1, Chapter 1"')
      expect(html).to include('role="status" aria-live="polite" data-block-say', "data-remove-dialog")
    end

    it "carries the markup of a new member as a template, with the index of a nested one left for the script",
       :aggregate_failures do
      expect(html).to match(/<template data-card-template data-kind="">.*draft_content\.chapters\.ZZI0ZZ\.heading/m)
      expect(html).to include("draft_content.chapters.ZZI0ZZ.parts.ZZI1ZZ.heading",
                              'id="blk-draft-content-chapters-ZZI0ZZ-parts-ZZI1ZZ"')
    end

    it "marks what a member is required to have as its value object declares, and what is optional", :aggregate_failures do
      part = card(html, "draft-content-chapters-0-parts", 0)

      expect(part).to include('data-requires="heading body"')
      expect(part).to match(/for="f-draft-content-chapters-0-parts-0-heading".*?title="Required"/m)
      expect(card(html, "draft-content-chapters",
                  0)).to include("Verse <span class=\"ml-1 text-xs font-normal text-muted\">optional</span>")
    end

    it "holds a group of its own as fields named by the member's index and the part's", :aggregate_failures do
      names = names_in(card(html, "draft-content-chapters", 0))

      expect(names).to include("draft_content.chapters.0.heading", "draft_content.chapters.0.parts.0.heading",
                               "draft_content.chapters.0.parts.0.body.blocks.0.kind", "draft_content.chapters.0.band.align.value")
    end

    it "draws a closed set as a choice, with none for an optional one", :aggregate_failures do
      first = card(html, "draft-content-chapters", 0)

      expect(first).to match(%r{<select[^>]*name="draft_content.chapters.0.band.align.value".*?<option value="">None</option>}m)
      expect(first).to include('<option value="center" selected>Center</option>')
    end
  end

  describe "a group of plain inputs that holds one of its own", if: EditorNode.available? do
    let(:html) { result("noteDraft") }

    it "stays a run of rows, the rows of its own nested, with a blank row to fill at each level", :aggregate_failures do
      expect(html).to include('data-repeat data-path="draft_content.rows"', 'data-repeat data-path="draft_content.rows.0.cells"')
      expect(html).to include('name="draft_content.rows.0.cells.1.text"', 'name="draft_content.rows.1.title"',
                              'name="draft_content.rows.0.cells.2.text"')
    end

    it "says the limit of the run, and carries it for the script", :aggregate_failures do
      expect(html).to include('data-noun="row" data-max="20"', 'data-noun="cell" data-max="8"', "At most 20.")
    end
  end

  describe "a picture slot", if: EditorNode.available? do
    let(:html) { result("storyDraft") }

    it "keeps the file and the description together with the picker's button, outside a list", :aggregate_failures do
      expect(html).to include('data-picture data-key="draft_content.hero.picture.media_ref"',
                              'data-alt="draft_content.hero.picture.alt"')
      expect(html).to match(%r{data-alt="draft_content.hero.picture.alt".*?data-action="pick-picture" data-media="/editor}m)
    end

    it "does the same in a member of a group, at any depth", :aggregate_failures do
      first = card(html, "draft-content-chapters", 0)

      expect(first).to include('data-picture data-key="draft_content.chapters.0.band.media_ref"',
                               'data-alt="draft_content.chapters.0.band.alt"')
      expect(first).to include('data-action="pick-picture"')
    end

    it "draws a list of pictures as cards that say the description, with the picker in each", :aggregate_failures do
      gallery = result("galleryDraft")

      expect(gallery).to include('data-summary-alt="alt"', 'data-requires="media_ref alt"', "data-card-summary>Red door</span>")
      expect(gallery).to include('data-picture data-key="draft_content.photos.0.media_ref" data-alt="draft_content.photos.0.alt"')
    end

    it "draws a picture of a person in a roster the same way, beside a writing box", :aggregate_failures do
      roster = result("rosterDraft")

      expect(roster).to include('data-picture data-key="draft_people.0.portrait.media_ref"')
      expect(roster).to match(/<textarea[^>]*name="draft_people.0.about"[^>]*maxlength="1000"/)
    end
  end

  describe "a writing box for a long text", if: EditorNode.available? do
    let(:html) { result("noteDraft") }

    it "is a textarea with its limit and a line that says it, for a text a rule bounds above 200", :aggregate_failures do
      expect(html).to match(/<textarea class="textarea [^"]*" rows="5" id="f-draft-content-summary"/)
      expect(html).to include('name="draft_content.summary" maxlength="600" aria-describedby="f-draft-content-summary-hint">')
      expect(html).to include('id="f-draft-content-summary-hint">Up to 600 characters.</p>')
    end

    it "keeps the line breaks of what is held, and a short text a single line with its limit", :aggregate_failures do
      expect(html).to include("Short.\nTwo lines.</textarea>")
      expect(html).to match(/<input type="text"[^>]*name="draft_content.heading"[^>]*maxlength="120"/)
    end
  end

  describe "the form turned back into the command's arguments", if: EditorNode.available? do
    def encoding(key) = result("encoding").fetch(key)

    it "sends the working copy whole: groups, their members in order, bodies and nested members", :aggregate_failures do
      content = encoding("whole").fetch("draft_content")
      band = { "media_ref" => "bb.png", "alt" => "Gate", "align" => { "value" => "center" } }

      expect(content["hero"]).to eq("heading" => "Hi", "picture" => { "media_ref" => "aa.png", "alt" => "Door" })
      expect(content["chapters"][0]).to include("heading" => "One", "band" => band)
      expect(content.dig("chapters", 1, "parts", 0, "body", "blocks", 0, "spans", 0, "text")).to eq("Part")
    end

    it "leaves out an optional group with nothing in it, at any depth", :aggregate_failures do
      content = encoding("blankGroupsLeftOut").fetch("draft_content")

      expect(content).not_to have_key("hero")
      expect(content["chapters"]).to eq([{ "heading" => "One", "parts" => [] }])
    end

    it "keeps a group with something in it whole, a required part sent empty so the domain words the refusal" do
      expect(encoding("halfFilledGroupKept").dig("draft_content", "chapters", 0,
                                                 "band")).to eq("media_ref" => "bb.png", "alt" => "")
    end

    it "drops a member left entirely empty, and keeps one that has anything", :aggregate_failures do
      expect(encoding("blankMemberDropped").dig("draft_content", "chapters").map { |one| one["heading"] }).to eq(["Two"])
      expect(encoding("blankPartDropped").dig("draft_content", "chapters", 0, "parts").map do |one|
        one["heading"]
      end).to eq(["Kept"])
    end

    it "orders members by their index, not by where their fields are in the form", :aggregate_failures do
      expect(encoding("order")).to eq(%w[First Second Third])
      expect(encoding("partsOrder")).to eq(%w[A B])
    end

    it "sends an empty list for a list nobody filled, so the domain refuses it in its own words" do
      expect(encoding("noChapters").dig("draft_content", "chapters")).to eq([])
    end

    it "sends nothing for the clearing argument of a value object, and an empty list for a list's",
       :aggregate_failures do
      expect(encoding("publishClears")).to eq({})
      expect(encoding("rosterPublishClears")).to eq("nothing" => [])
      expect(encoding("rosterDiscardClears")).to eq("nothing" => [])
    end

    it "drops the member of a list whose parts are all blank, and a picture with nothing in it", :aggregate_failures do
      people = encoding("rosterList").fetch("draft_people")

      expect(people.map { |one| one["name"] }).to eq(["Ann"])
      expect(people[0]).not_to have_key("portrait")
    end

    it "reads a line break as the one character the domain holds" do
      expect(encoding("crlf")).to eq("One\nTwo")
    end
  end

  describe "which part of the page a refusal is about", if: EditorNode.available? do
    def refusal(key) = result("refusals").fetch(key)

    it "finds the group whose value the refusal echoes, and not one that differs in a part", :aggregate_failures do
      found = refusal("bandNotDescribed")

      expect(found.map { |one| one["name"] }).to eq(["draft_content.chapters.1.band"])
      expect(found.first).to include("message" => "A band is described.", "slots" => ["alt"])
    end

    it "finds the only group of its type when nothing is echoed, and the slot it lacks", :aggregate_failures do
      found = refusal("onlyOneOfItsType")

      expect(found.map { |one| one["name"] }).to eq(["draft_content.chapters.1.verse"])
      expect(found.first["slots"]).to eq(["body"])
    end

    it "names nothing when several groups could be it and nothing says which" do
      expect(refusal("ambiguous")).to eq([])
    end

    it "finds the member of a list by its own rule, with its path in the arguments", :aggregate_failures do
      found = refusal("chapterSaysNothing")

      expect(found.map { |one| one["name"] }).to eq(["draft_content.chapters.1"])
      expect(found.first["path"]).to eq(["draft_content", "chapters", 1])
    end

    it "finds a member of a group inside a member, at depth two" do
      expect(refusal("partOfAChapter").map { |one| one["name"] }).to eq(["draft_content.chapters.0.parts.1"])
    end

    it "finds the rule of the content as a whole, and the part of it that is short", :aggregate_failures do
      found = refusal("contentRule")

      expect(found.map { |one| one["name"] }).to eq(["draft_content"])
      expect(found.first["slots"]).to eq(["chapters"])
    end

    it "finds a picture in a hero as it finds one anywhere" do
      expect(refusal("heroPicture").map { |one| [one["name"], one["slots"]] }).to eq([["draft_content.hero.picture", ["alt"]]])
    end

    it "names nothing for a refusal that is not about a value of the arguments" do
      expect(refusal("notAboutAValue")).to eq([])
    end
  end

  describe "what is drawn as a card and what stays a row", if: EditorNode.available? do
    it "takes a member that holds a body or a picture for a card, and a plain one, rows of its own too, for a row",
       :aggregate_failures do
      # A picture is a card when it is a member itself: the list attribute says so (`picture`).
      expect(result("heavy")).to eq("chapters" => true, "part" => true, "hero" => true, "band" => false, "key" => false,
                                    "row" => false, "cell" => false)
    end

    it "stands for a picture by its description, a member by what it holds", :aggregate_failures do
      expect(result("summaries")).to eq(["Red door", "aa.png", "One", "2 parts"])
    end
  end

  describe "saving, publishing and discarding", if: EditorNode.available? do
    it "sends the whole working copy in one command, in order, and returns to where it came from", :aggregate_failures do
      saved = result("saved")

      expect(saved["status"]).to eq(303)
      expect(saved["sent"].map { |sent| sent["verb"] }).to eq(["Leaflets::ChaptersPage.SaveDraft"])
      expect(result("afterSave")).to eq(%w[Moved Then])
    end

    it "saves an autosave as a draft only, never the live content, in plain text", :aggregate_failures do
      auto = result("autosaved")

      expect(auto).to include("status" => 200, "text" => "Saved.", "sent" => ["Leaflets::ChaptersPage.SaveDraft"])
      expect(result("liveAfterAutosave")).to eq(12)
    end

    it "answers a refused autosave with the words and the groups it names", :aggregate_failures do
      refused = result("autosaveRefused")

      expect(refused["status"]).to eq(422)
      expect(refused["problems"]).to eq([{ "path" => ["draft_content", "chapters", 0, "band"],
                                           "name" => "draft_content.chapters.0.band", "slots" => ["alt"],
                                           "message" => "A band is described." }])
    end

    it "shows a refused save's group open, marked and described, beside the field it names", :aggregate_failures do
      html = result("refusedPage")["html"]

      expect(result("refusedPage")["status"]).to eq(422)
      expect(html).to match(/name="draft_content\.chapters\.0\.band\.alt"[^>]*aria-invalid="true"[^>]*aria-describedby=/)
      expect(html).to include('aria-describedby="f-draft-content-chapters-0-band-alt-error"')
      expect(html).to include('id="f-draft-content-chapters-0-band-alt-error">A band is described.</p>')
    end

    it "opens the card that holds a refused field, and keeps what was sent", :aggregate_failures do
      html = result("refusedPage")["html"]

      expect(html).to include("data-open", 'aria-expanded="true"', 'value="Kept"')
      expect(html).to include('value="bb.png"')
    end

    it "publishes the working copy and clears it with no argument", :aggregate_failures do
      published = result("published")

      expect(published["live"]).to eq(1)
      expect(published["sent"].map { |sent| sent["verb"] }).to eq(["Leaflets::ChaptersPage.PublishDraft"])
    end

    it "discards a working copy that is a list with an empty list as the clearing argument", :aggregate_failures do
      discarded = result("discarded")

      expect(discarded).to include("draft" => false, "live" => 1)
      expect(discarded["sent"]).to eq([{ "verb" => "Leaflets::RosterPage.DiscardDraft", "with" => { "nothing" => [] } }])
    end
  end

  describe "the scripts", if: EditorNode.available? do
    def parses?(name)
      script = files.fetch(name).sub(/^const loadPicker = .*$/, "const loadPicker = null;")
      Dir.mktmpdir("fixed_pages_script") do |dir|
        File.write(File.join(dir, "script.mjs"), script)
        Open3.capture2e("node", "--check", File.join(dir, "script.mjs")).last.success?
      end
    end

    it "are modules node can parse", :aggregate_failures do
      %w[src/browser/blocks.js src/browser/forms.js src/browser/moments.js src/browser/autosave.js
         src/ui/block_list.js].each { |name| expect(parses?(name)).to be(true), name }
    end
  end
end
