require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "hecks/tools"
require "hecks/tools/site_routes"
require_relative "support/editor_node"

# The editor working on a page as an ordered list of mixed blocks, run under node against a stand-in
# host (spec/support/editor_stand_in_host.mjs): the cards the list is drawn as, the form each kind
# shows, how a form is turned back into the command's arguments, and which card a refusal is
# about. The pure halves (the encoding and the mapping of a refusal) are run over tables.
BLOCKS_NODE_SCENARIO = <<~JS.freeze
  import { accountToken } from "@hecks/client";
  import { mkdirSync, writeFileSync } from "node:fs";
  import { createApp } from "./editor/src/app.ts";
  import { SCHEMA } from "./editor/src/schema.ts";
  import { commandArguments, parseForm } from "./editor/src/ui/input.ts";
  import { problemsOf, slotsOf, summaryOf, kindOf, lacking, retarget } from "./editor/src/ui/block_list.js";
  import { standInHost } from "./host.mjs";

  const SECRET = "scenario-secret";
  const now = 1_800_000_000;
  const v = (value) => ({ value });
  const text = (words) => ({ blocks: [{ kind: "paragraph", spans: [{ text: words, marks: [] }], items: [] }] });
  const hero = { kind: v("hero"), heading: "Welcome", links: [{ label: "Go", href: "/go" }], entries: [] };
  const faq = { kind: v("faq"), links: [], entries: [{ heading: "Why?", body: text("Because.") }, { heading: "When?", body: text("Now.") }] };
  const live = { kind: v("text"), heading: "Live heading", links: [], entries: [] };
  const instances = {
    "Layouts::PageLayout#page:home": { key: v("page:home"), panels: [live], draft_panels: [hero, faq] },
    "Layouts::PageLayout#page:fresh": { key: v("page:fresh"), panels: [live], draft_panels: [] },
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
  const PAGE = "/editor/Layouts/PageLayout/id/page%3Ahome";
  const out = {};

  out.draftPage = await (await admin(`${PAGE}/SaveDraft`)).text();
  out.freshPage = await (await admin("/editor/Layouts/PageLayout/id/page%3Afresh/SaveDraft")).text();
  out.detail = await (await admin(PAGE)).text();
  out.newPage = await (await admin("/editor/Layouts/PageLayout/new/Lay")).text();

  const layout = SCHEMA.aggregates.find((agg) => agg.name === "PageLayout");
  const attrs = layout.commands.find((command) => command.name === "SaveDraft").attributes;
  const list = attrs[0].blockList;
  const parts = layout.valueObjects.Panel;
  const encode = (body, name = "SaveDraft", empty) => {
    const command = layout.commands.find((candidate) => candidate.name === name);
    return commandArguments(layout, command.attributes, parseForm(body), empty ?? command.empty ?? []);
  };
  out.encoding = {
    whole: encode("draft_panels.0.kind.value=hero&draft_panels.0.heading=Hi&draft_panels.0.links.0.label=Go&draft_panels.0.links.0.href=%2Fgo&draft_panels.1.kind.value=text&draft_panels.1.body.blocks.0.kind=paragraph&draft_panels.1.body.blocks.0.spans.0.text=Hello"),
    entries: encode("draft_panels.0.kind.value=faq&draft_panels.0.entries.0.heading=Why%3F&draft_panels.0.entries.0.body.blocks.0.kind=paragraph&draft_panels.0.entries.0.body.blocks.0.spans.0.text=Because&draft_panels.0.entries.1.heading=&draft_panels.0.entries.2.heading=When%3F"),
    emptyRowsDropped: encode("draft_panels.0.kind.value=hero&draft_panels.0.heading=Hi&draft_panels.0.links.0.label=&draft_panels.0.links.0.href=&draft_panels.0.links.0.variant="),
    kindOnlyKept: encode("draft_panels.0.kind.value=cards&draft_panels.0.heading="),
    numbers: encode("draft_panels.0.kind.value=hero&draft_panels.0.heading=Hi&draft_panels.0.heading_level=2"),
    blankIsAbsent: encode("draft_panels.0.kind.value=hero&draft_panels.0.heading=Hi&draft_panels.0.subheading=&draft_panels.0.summary="),
    order: encode("draft_panels.1.kind.value=text&draft_panels.1.heading=Second&draft_panels.0.kind.value=hero&draft_panels.0.heading=First").draft_panels.map((panel) => panel.heading),
    publishClears: encode("", "PublishDraft"),
    discardClears: encode("", "DiscardDraft"),
  };

  const refused = (error, args) => problemsOf(error, attrs, args, layout.valueObjects).map((problem) => ({ path: problem.path, slots: problem.slots, message: problem.message }));
  const echo = (panel) => JSON.stringify({ ...panel, links: panel.links ?? [], entries: panel.entries ?? [], body: null, heading: panel.heading ?? null });
  const list2 = [hero, { kind: v("hero"), links: [], entries: [] }, { kind: v("hero"), links: [], entries: [] }];
  const cards = { kind: v("cards"), links: [], entries: [{ heading: "A", summary: "x" }, { summary: "no heading" }] };
  out.refusals = {
    echoed: refused(`Panel invariant violated — a hero has a heading (given ${echo({ kind: v("hero") })})`, { draft_panels: list2 }),
    nested: refused(`Entry invariant violated — an entry says something (given ${JSON.stringify({ heading: null, summary: null, body: null, media_ref: null, alt: null, href: null, link_label: null })})`, { draft_panels: [hero, { kind: v("cards"), links: [], entries: [{ heading: "A" }, {}] }] }),
    wordedOnly: refused("Panel invariant violated — cards have entries, each with a heading", { draft_panels: [hero, cards] }),
    notAboutAList: refused("Governance refused — not allowed", { draft_panels: list2 }),
    noMatch: refused(`Panel invariant violated — a hero has a heading (given ${echo({ kind: v("hero"), heading: "Other" })})`, { draft_panels: [faq] }),
    picture: refused(`Panel invariant violated — a picture is described (given ${JSON.stringify({ kind: { value: "image" }, media_ref: "m.png", links: [], entries: [] })})`, { draft_panels: [{ kind: v("image"), media_ref: "m.png", links: [], entries: [] }] }),
  };

  out.slots = {
    hero: slotsOf(list, parts, "hero").map((slot) => [slot.part.name, slot.required]),
    faq: slotsOf(list, parts, "faq").map((slot) => slot.part.name),
    image: slotsOf(list, parts, "image").map((slot) => slot.part.name),
    summaries: [summaryOf(list, parts, hero), summaryOf(list, parts, faq), summaryOf(list, parts, { kind: v("cards"), links: [], entries: [] })],
    kind: [kindOf(list, hero), kindOf({ discriminator: "kind" }, { kind: "plain" }), kindOf(list, {})],
    lacking: [lacking(list, parts, { kind: v("hero") }), lacking(list, parts, hero), lacking(list, parts, { kind: v("image"), media_ref: "m.png" }, list.pictures.Panel)],
  };

  out.retarget = [
    retarget('name="list.3.heading" id="f-list-3-heading" for="f-list-3-heading"', "list", "3", "2"),
    retarget('name="list.3.entries.1.body.blocks.0.kind" data-path="list.3.entries" id="blk-list-3-entries-1"', "list", "3", "0"),
    retarget('name="list.13.heading" id="f-list-13-heading"', "list", "1", "0"),
    retarget('name="list.3.links.ZZI1ZZ.label" id="f-list-3-links-ZZI1ZZ-label"', "list", "3", "7"),
    retarget('name="list.3.links.0.label"', "list.3.links", "0", "1"),
  ];

  host.sent.length = 0;
  const saved = await admin(`${PAGE}/SaveDraft`, post("draft_panels.0.kind.value=hero&draft_panels.0.heading=Moved&draft_panels.1.kind.value=text&draft_panels.1.heading=Then&__back=%2Feditor", {}));
  out.saved = { status: saved.status, location: saved.headers.get("location"), sent: host.sent.filter((body) => body.verb).map((body) => ({ verb: body.verb, to: body.to, with: body.with })) };
  out.afterSave = instances["Layouts::PageLayout#page:home"].draft_panels.map((panel) => panel.heading);

  host.sent.length = 0;
  const auto = await admin(`${PAGE}/SaveDraft`, post("draft_panels.0.kind.value=quote&draft_panels.0.summary=Said", { "x-editor-autosave": "1" }));
  out.autosaved = { status: auto.status, text: await auto.text(), sent: host.sent.filter((body) => body.verb).map((body) => body.verb) };
  out.liveAfterAutosave = instances["Layouts::PageLayout#page:home"].panels.map((panel) => panel.heading);

  const violation = (given) => ({ kind: "InvariantViolation", error: `Panel invariant violated — a hero has a heading (given ${JSON.stringify(given)})` });
  host.refuseNext("SaveDraft", violation({ kind: v("hero"), links: [], entries: [] }));
  const refusedAuto = await admin(`${PAGE}/SaveDraft`, post("draft_panels.0.kind.value=text&draft_panels.0.heading=Fine&draft_panels.1.kind.value=hero", { "x-editor-autosave": "1" }));
  out.autosaveRefused = { status: refusedAuto.status, text: await refusedAuto.text(), problems: JSON.parse(decodeURIComponent(refusedAuto.headers.get("x-editor-problems") ?? "null")) };

  host.refuseNext("SaveDraft", violation({ kind: v("hero"), links: [], entries: [] }));
  const refusedPage = await admin(`${PAGE}/SaveDraft`, post("draft_panels.0.kind.value=text&draft_panels.0.heading=Fine&draft_panels.1.kind.value=hero"));
  out.refusedPage = { status: refusedPage.status, html: await refusedPage.text() };

  console.log(JSON.stringify(out));
JS

RSpec.describe "the generated block list editor, run by node" do
  let(:project) { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/editor_sections") }

  def files
    projected = Hecks::Tools::SiteRoutes.projection(project, out: "/work/out", editor: "/work/editor")
    projected.select { |path, _| path.start_with?("/work/editor/") }.transform_keys { |path| path.delete_prefix("/work/editor/") }
  end

  def run
    host = File.read(File.join(InMemoryDomain::ROOT, "spec/support/editor_stand_in_host.mjs"))
    @run ||= EditorNode.run(files, BLOCKS_NODE_SCENARIO, extra: { "host.mjs" => host })
  end

  def result(key) = run.fetch(key)

  # The card of the list that starts at `id`, up to the start of the next card of its level.
  def card(html, index)
    after = "<li class=\"[^\"]*\" id=\"blk-draft-panels-#{index + 1}\"|</ol>\n<p class=\"mt-2"
    html[/<li class="[^"]*" id="blk-draft-panels-#{index}" data-card.*?(?=#{after})/m]
  end

  # What `retarget` answers for the five spellings the scenario gives it.
  def renamed
    [
      'name="list.2.heading" id="f-list-2-heading" for="f-list-2-heading"',
      'name="list.0.entries.1.body.blocks.0.kind" data-path="list.0.entries" id="blk-list-0-entries-1"',
      'name="list.13.heading" id="f-list-13-heading"',
      'name="list.7.links.ZZI1ZZ.label" id="f-list-7-links-ZZI1ZZ-label"',
      'name="list.3.links.1.label"'
    ]
  end

  def names_in(html) = html.scan(/ name="(draft_panels\.\d+\.[a-z_.0-9]+)"/).flatten

  describe "the form of a list of blocks", if: EditorNode.available? do
    it "draws each block as a card, in order, with its kind and one line that says what it holds", :aggregate_failures do
      html = result("draftPage")

      expect(html.scan(/data-card data-index="\d+" data-kind="(?:hero|faq)"/).size).to eq(2)
      expect(html).to include("data-kind-badge>Hero</span>", "data-kind-badge>Faq</span>", "data-card-summary>Welcome</span>",
                              "2 entries")
    end

    it "shows the count of blocks, and a polite live region that says what moved", :aggregate_failures do
      html = result("draftPage")

      expect(html).to include("data-count>(2)</span>", 'role="status" aria-live="polite" data-block-say')
    end

    it "gives each card move up, move down and remove buttons that name the card, shown by the script", :aggregate_failures do
      first = card(result("draftPage"), 0)

      expect(first).to include('data-action="up"', 'data-action="down"', 'data-action="remove"',
                               'aria-label="Move up panel 1, Welcome"')
      expect(first).to include("data-tools hidden")
    end

    it "asks before a block is removed, in a native dialog the list carries", :aggregate_failures do
      html = result("draftPage")

      expect(html).to include('<dialog class="modal" id="blk-draft-panels-remove"', 'data-action="remove-confirm"',
                              'data-action="remove-cancel"')
    end

    it "shows a hero the slots it uses, and the slots every kind has", :aggregate_failures do
      hero = names_in(card(result("draftPage"), 0))

      expect(hero).to include("draft_panels.0.heading", "draft_panels.0.links.0.label", "draft_panels.0.variant")
      expect(hero).not_to include("draft_panels.0.body.blocks.0.kind", "draft_panels.0.size", "draft_panels.0.entries.0.heading")
    end

    it "shows a faq its entries, and none of the slots only other kinds use", :aggregate_failures do
      faq = names_in(card(result("draftPage"), 1))

      expect(faq).to include("draft_panels.1.entries.0.heading", "draft_panels.1.variant")
      expect(faq).not_to include("draft_panels.1.heading", "draft_panels.1.summary")
    end

    it "carries what a kind requires, to hold back a save that is not ready", :aggregate_failures do
      expect(card(result("draftPage"), 0)).to include('data-requires="heading"')
      expect(card(result("draftPage"), 1)).to include('data-requires="entries"')
    end

    it "puts the slots a kind needs before the ones it may use and the ones every kind has" do
      names = names_in(card(result("draftPage"), 0)).grep(/\Adraft_panels\.0\.(heading|summary|variant)\z/)

      expect(names).to eq(%w[draft_panels.0.heading draft_panels.0.summary draft_panels.0.variant])
    end

    it "keeps the picture's key and description together, with the picker's button when there are pictures",
       :aggregate_failures do
      first = card(result("draftPage"), 0)

      expect(first).to include('data-picture data-key="draft_panels.0.media_ref" data-alt="draft_panels.0.alt"',
                               'data-action="pick-picture"')
    end

    it "carries the markup of a new block of each kind as a template, for the script to add", :aggregate_failures do
      html = result("draftPage")
      kinds = html.scan(/<template data-card-template data-kind="([a-z_]+)">/).flatten

      expect(kinds).to eq(%w[hero text image columns cards quote call_to_action gallery faq profile])
      expect(html).to include("draft_panels.ZZI0ZZ.kind.value", 'id="blk-draft-panels-ZZI0ZZ"')
    end

    it "carries the template of a repeated part in the card that holds it", :aggregate_failures do
      first = card(result("draftPage"), 0)

      expect(first).to include('data-path="draft_panels.0.links" data-noun="link" data-max="8"')
      expect(first).to match(/<template data-card-template data-kind="">.*draft_panels\.0\.links\.ZZI1ZZ\.label/m)
    end

    it "starts a draft from the live blocks when none is saved", :aggregate_failures do
      html = result("freshPage")

      expect(names_in(html)).to include("draft_panels.0.heading")
      expect(html).to include('value="Live heading"', "No draft is saved yet.")
    end

    it "says a draft is saved only when it holds a block" do
      expect(result("draftPage")).to include("A draft is saved.")
    end

    it "lists the blocks read-only on the page of the record, with their kind", :aggregate_failures do
      expect(result("detail")).to include('<ol class="grid list-decimal gap-1 pl-6">', "Welcome", "Faq")
    end

    it "offers the command that makes a layout the same list, empty" do
      expect(result("newPage")).to include("data-block-list", "No panel")
    end
  end

  describe "the form turned back into the command's arguments", if: EditorNode.available? do
    def encoding(key) = result("encoding").fetch(key)

    it "sends the whole list in the order the fields name, nested lists and bodies included", :aggregate_failures do
      panels = encoding("whole").fetch("draft_panels")

      expect(panels.map { |panel| panel["kind"] }).to eq([{ "value" => "hero" }, { "value" => "text" }])
      expect(panels[0]).to include("heading" => "Hi", "links" => [{ "label" => "Go", "href" => "/go" }])
      expect(panels[1]["body"]).to eq("blocks" => [{ "kind" => "paragraph", "spans" => [{ "text" => "Hello", "marks" => [] }],
"items" => [] }])
    end

    it "orders blocks by their index, not by where their fields are in the form" do
      expect(encoding("order")).to eq(%w[First Second])
    end

    it "drops an entry that was left entirely empty, and keeps one that has anything", :aggregate_failures do
      entries = encoding("entries").dig("draft_panels", 0, "entries")

      expect(entries.map { |entry| entry["heading"] }).to eq(["Why?", "When?"])
      expect(entries[0].dig("body", "blocks", 0, "spans", 0, "text")).to eq("Because")
    end

    it "drops a repeated row left empty, sending the list empty" do
      expect(encoding("emptyRowsDropped").dig("draft_panels", 0, "links")).to eq([])
    end

    it "keeps a block that holds only its kind, so the domain refuses it in its own words, leaving out an empty body",
       :aggregate_failures do
      panel = encoding("kindOnlyKept").dig("draft_panels", 0)

      expect(panel).to eq("kind" => { "value" => "cards" }, "links" => [], "entries" => [])
    end

    it "leaves out an optional slot left blank, and reads a number as a number", :aggregate_failures do
      expect(encoding("blankIsAbsent").dig("draft_panels", 0)).not_to include("subheading", "summary")
      expect(encoding("numbers").dig("draft_panels", 0, "heading_level")).to eq(2)
    end

    it "sends the clearing argument as an empty list when the draft is published or thrown away", :aggregate_failures do
      expect(encoding("publishClears")).to eq("nothing" => [])
      expect(encoding("discardClears")).to eq("nothing" => [])
    end
  end

  describe "which block a refusal is about", if: EditorNode.available? do
    def refusal(key) = result("refusals").fetch(key)

    it "finds the block whose value the refusal echoes, among blocks that differ", :aggregate_failures do
      found = refusal("echoed")

      expect(found.map { |problem| problem["path"] }).to eq([["draft_panels", 1], ["draft_panels", 2]])
      expect(found.first).to include("message" => "A hero has a heading.", "slots" => ["heading"])
    end

    it "finds an entry of a block, with the path that leads to it" do
      expect(refusal("nested").map { |problem| problem["path"] }).to eq([["draft_panels", 1, "entries", 1]])
    end

    it "falls back to the blocks whose kind the rule's words name when nothing is echoed" do
      expect(refusal("wordedOnly").map { |problem| problem["path"] }).to eq([["draft_panels", 1]])
    end

    it "names nothing for a refusal that is not about a block, or about one that is not there", :aggregate_failures do
      expect(refusal("notAboutAList")).to eq([])
      expect(refusal("noMatch")).to eq([])
    end

    it "names the alt text when it is a picture that is not described" do
      expect(refusal("picture").first).to include("slots" => ["alt"])
    end
  end

  describe "the rules a kind shows", if: EditorNode.available? do
    def slots(key) = result("slots").fetch(key)

    it "orders a kind's slots as needed, used, then common to every kind", :aggregate_failures do
      names = slots("hero").map(&:first)

      expect(names.first(5)).to eq(%w[heading subheading summary media_ref alt])
      expect(slots("hero").first.last).to be(true)
    end

    it "leaves out the slots a kind has no use for", :aggregate_failures do
      expect(slots("faq")).to include("entries", "variant")
      expect(slots("faq")).not_to include("heading", "body", "media_ref")
    end

    it "brings a picture's alt text with its key" do
      expect(slots("image").first(3)).to eq(%w[media_ref alt caption])
    end

    it "stands for a block by its first required text, else by what it holds" do
      expect(slots("summaries")).to eq(["Welcome", "2 entries", ""])
    end

    it "reads a kind as a plain value or as a one-part value object, or as nothing" do
      expect(slots("kind")).to eq(%w[hero plain] + [""])
    end

    it "says what a block lacks: a required slot, and a picture's description" do
      expect(slots("lacking")).to eq([[{ "slot" => "heading", "message" => "heading is needed" }], [],
                                      [{ "slot" => "alt", "message" => "Describe the picture for people who cannot see it" }]])
    end
  end

  describe "renumbering a card's fields after a move", if: EditorNode.available? do
    it "renames a field's name and the id made from it, and what is nested in the card" do
      expect(result("retarget")).to eq(renamed)
    end
  end

  describe "the block list's script", if: EditorNode.available? do
    def parses?(script)
      Dir.mktmpdir("blocks_script") do |dir|
        File.write(File.join(dir, "blocks.mjs"), script.sub(/^const loadPicker = .*$/, "const loadPicker = null;"))
        Open3.capture2e("node", "--check", File.join(dir, "blocks.mjs")).last.success?
      end
    end

    it "is a module node can parse" do
      expect(parses?(files.fetch("src/browser/blocks.js"))).to be(true)
    end
  end

  describe "saving the list", if: EditorNode.available? do
    it "sends the whole list in one command, in order, and returns to where it came from", :aggregate_failures do
      saved = result("saved")

      expect(saved["status"]).to eq(303)
      expect(saved["sent"].map { |sent| sent["verb"] }).to eq(["Layouts::PageLayout.SaveDraft"])
      expect(result("afterSave")).to eq(%w[Moved Then])
    end

    it "saves an autosave as a draft only, never the live list, in plain text", :aggregate_failures do
      auto = result("autosaved")

      expect(auto).to include("status" => 200, "text" => "Saved.", "sent" => ["Layouts::PageLayout.SaveDraft"])
      expect(result("liveAfterAutosave")).to eq(["Live heading"])
    end

    it "answers a refused autosave with the words and the blocks it names", :aggregate_failures do
      refused = result("autosaveRefused")

      expect(refused["status"]).to eq(422)
      expect(refused["problems"]).to eq([{ "path" => ["draft_panels", 1], "name" => "draft_panels.1", "slots" => ["heading"],
                                           "message" => "A hero has a heading." }])
    end

    it "shows a refused save's block open, marked and described, with a summary at the top", :aggregate_failures do
      html = result("refusedPage")["html"]

      expect(result("refusedPage")["status"]).to eq(422)
      expect(html).to include("data-block-problems", "1 panel needs attention", "Needs attention", 'aria-expanded="true"')
      expect(html).to match(/name="draft_panels\.1\.heading"[^>]*aria-invalid="true"[^>]*aria-describedby=/)
    end

    it "keeps what was sent in the form that is shown again", :aggregate_failures do
      html = result("refusedPage")["html"]

      expect(html).to include('value="Fine"')
      expect(html).to include('draft_panels.1.kind.value" value="hero"')
    end
  end
end
