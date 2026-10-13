require "spec_helper"
require "json"
require "hecks/tools"
require "hecks/tools/site_routes"
require_relative "support/editor_node"

# The editor's task words, run under node against the stand-in host: the home page of jobs, the
# form of a plant (a moment in a fixed zone, a record picked by its name, fields kept behind "More
# options", an address made from the name), what is sent to the host, a moment left untouched
# keeping its spelling, the note that goes with a record, and a refusal said in words.
TASKS_NODE_SCENARIO = <<~JS.freeze
  import { accountToken } from "@hecks/client";
  import { mkdirSync, writeFileSync } from "node:fs";
  import { createApp } from "./editor/src/app.ts";
  import { SCHEMA } from "./editor/src/schema.ts";
  import { standInHost } from "./host.mjs";

  const SECRET = "scenario-secret";
  const now = 1_800_000_000;
  const v = (value) => ({ value });
  const instances = {
    "Garden::Plant#thyme": { slug: v("thyme"), name: v("Thyme"), kind: v("herb"), bed_slug: v("herb-spiral"), sown_on: v("2026-11-07T17:00:00.000Z"), visits: [{ at: "2026-11-08T17:30:00.000Z", note: "In flower." }], status: "draft" },
    "Garden::Plant#oak": { slug: v("oak"), name: v("Oak"), kind: v("tree"), visits: [], status: "listed" },
    "Garden::Bed#herb-spiral": { slug: v("herb-spiral"), title: v("The herb spiral") },
    "Garden::Bed#north-row": { slug: v("north-row"), title: v("North row") },
    "Garden::Gardener#ana": { key: v("ana"), name: v("Ana Ruiz") },
    "Garden::Gardener#thyme": { key: v("thyme"), name: v("Thyme Keeper") },
    "Garden::Almanac#almanac": { key: v("almanac"), motto: v("Water early.") },
    "Garden::Note#plant.thyme.note": { slug: v("plant.thyme.note"), kind: v("plant"), address: v("thyme"), text: v("Pinch the tips."), written_at: v(1_700_000_000) },
  };
  const host = standInHost(SCHEMA, { instances });
  mkdirSync(`${import.meta.dirname}/editor/dist`, { recursive: true });
  writeFileSync(`${import.meta.dirname}/editor/dist/editor.css`, "body { margin: 0; }\\n");
  writeFileSync(`${import.meta.dirname}/editor/dist/editor.js`, "export {};\\n");
  const app = createApp({ fetch: host.fetch, secret: SECRET, url: "http://host.test", now: () => now * 1000 });
  const form = { "Content-Type": "application/x-www-form-urlencoded", Origin: "http://site.test" };
  const call = (path, init = {}) => app(new Request(`http://site.test${path}`, init));
  const token = accountToken(SECRET, "ed@example.org", 60, { now: () => now * 1000 });
  const cookie = (await call(`/editor/api/sso?token=${token}`)).headers.get("set-cookie").split(";")[0];
  const admin = (path, init = {}) => call(path, { ...init, headers: { cookie, ...(init.headers ?? {}) } });
  const post = (body, extra = {}) => ({ method: "POST", body, headers: { ...form, ...extra } });
  const sentVerbs = () => host.sent.filter((one) => one.verb).map((one) => ({ verb: one.verb, to: one.to, with: one.with, role: one.role }));
  const out = {};

  out.home = await (await admin("/editor")).text();
  out.newPlant = await (await admin("/editor/Plant/new/Sow")).text();
  out.reviseThyme = await (await admin("/editor/Plant/id/thyme/Revise")).text();
  out.detailThyme = await (await admin("/editor/Plant/id/thyme")).text();
  out.detailOak = await (await admin("/editor/Plant/id/oak")).text();
  out.noPreview = await (await admin("/editor/Bed/id/north-row")).text();
  out.noteForm = await (await admin("/editor/Note/new/Write?slug.value=plant.oak.note&_back=%2Feditor%2FPlant%2Fid%2Foak")).text();
  out.list = await (await admin("/editor/Plant")).text();
  out.family = await (await admin("/editor/plots")).text();
  out.detailKeeper = await (await admin("/editor/Gardener/id/thyme")).text();
  out.notFound = (await call("/editor/api/sso?token=garbage")).status;
  out.notFoundText = await (await call("/editor/api/sso?token=garbage")).text();

  host.sent.length = 0;
  const made = await admin("/editor/Plant/new/Sow", post("name.value=Sweet+Basil&kind.value=herb&sown_on.value=2026-11-07T10%3A00&visits.0.at=2026-11-09T08%3A15&visits.0.note=Sprouting&slug.value="));
  out.made = { status: made.status, location: made.headers.get("location"), sent: sentVerbs() };

  host.sent.length = 0;
  await admin("/editor/Plant/id/thyme/Revise", post("name.value=Thyme&kind.value=herb&sown_on.value=2026-11-07T10%3A00&sown_on.value__held=2026-11-07T17%3A00%3A00.000Z&visits.0.at=2026-11-08T10%3A30&visits.0.at__held=2026-11-08T17%3A30%3A00.000Z&visits.0.note=In+flower."));
  out.untouched = sentVerbs();

  host.sent.length = 0;
  await admin("/editor/Plant/id/thyme/Revise", post("name.value=Thyme&sown_on.value=2026-11-07T11%3A00&sown_on.value__held=2026-11-07T17%3A00%3A00.000Z"));
  out.changed = sentVerbs();

  host.sent.length = 0;
  await admin("/editor/Note/new/Write", post("slug.value=plant.oak.note&text.value=Old+and+wide.&kind.value=&address.value=&written_at.value=&__back=%2Feditor%2FPlant%2Fid%2Foak"));
  out.noteMade = sentVerbs();

  host.refuseNext("Sow", { kind: "InvariantViolation", error: 'PlantName invariant violated \\u2014 a plant has a name (given {"value":""})' });
  const refused = await admin("/editor/Plant/new/Sow", post("name.value=Dock&kind.value=herb"));
  out.blankName = await (await admin("/editor/Plant/new/Sow", post("name.value=&kind.value=herb&slug.value="))).text();
  out.refused = { status: refused.status, html: await refused.text() };
  host.refuseNext("Sow", { kind: "InvariantViolation", error: "Visit.at expects String, got nil" });
  out.shape = await (await admin("/editor/Plant/new/Sow", post("name.value=Dock"))).text();
  console.log(JSON.stringify(out));
JS

RSpec.describe "the generated task editor, run by node" do
  let(:project) { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/editor_tasks") }

  def files
    projected = Hecks::Tools::SiteRoutes.projection(project, out: "/work/out", editor: "/work/editor")
    projected.select { |path, _| path.start_with?("/work/editor/") }.transform_keys { |path| path.delete_prefix("/work/editor/") }
  end

  def run
    host = File.read(File.join(InMemoryDomain::ROOT, "spec/support/editor_stand_in_host.mjs"))
    @run ||= EditorNode.run(files, TASKS_NODE_SCENARIO, extra: { "host.mjs" => host })
  end

  def result(key) = run.fetch(key)

  describe "the home page", if: EditorNode.available? do
    it "is a card of jobs for each aggregate, each job in the words the rows and the model give", :aggregate_failures do
      html = result("home")

      expect(html).to include("What would you like to do?", ">New plant</a>", "Start a plant the catalogue does not list yet")
      expect(html).to include(">Edit plants</a>", "The plants the garden grows.")
    end

    it "goes straight to the one record of an aggregate that holds one, and offers no second", :aggregate_failures do
      html = result("home")

      expect(html).to include(">Change almanac</a>", 'href="/editor/Almanac/id/almanac"')
      expect(html).not_to include("New almanac")
    end

    it "keeps the aggregates a row calls advanced behind one fold" do
      expect(result("home")).to match(%r{<details[^>]*><summary[^>]*>More</summary>.*Notes.*</details>}m)
    end
  end

  describe "a family of aggregates", if: EditorNode.available? do
    it "is one card on the home page in place of its members' cards, with a task for each member", :aggregate_failures do
      html = result("home")

      expect(html).to include("task-family-plots", ">Edit plots</a>", "Beds and the people who tend them.")
      expect(html).to include(">New bed</a>", ">New gardener</a>")
      expect(html).not_to include("task-Bed", "task-Gardener", "Edit beds")
    end

    it "lists every record of every member, named by the record that shares its address, and what each is", :aggregate_failures do
      html = result("family")

      expect(html).to include("4 plots", ">Plots<")
      expect(html).to include(">Thyme<", "thyme", ">Gardener<", ">Bed<", ">ana<")
    end

    it "titles a member's own page by that name", :aggregate_failures do
      html = result("detailKeeper")

      expect(html).to include('<h1 class="break-words text-3xl">Thyme</h1>')
    end
  end

  describe "the form of a plant", if: EditorNode.available? do
    let(:html) { result("newPlant") }

    it "is titled by what it makes, and has the label and help the rows give", :aggregate_failures do
      expect(html).to include("<h1 class=\"text-3xl\">New plant</h1>", "Looked after by", "When the seed went in.")
    end

    it "keeps the address behind more options, and says it is filled in when left blank", :aggregate_failures do
      expect(html).to include("data-advanced", "More options", "filled in if left blank")
      expect(html.index("More options")).to be > html.index('name="name.value"')
      expect(html.index('name="slug.value"')).to be > html.index("More options")
    end

    it "takes a moment as the clock of its zone and says which", :aggregate_failures do
      expect(html).to include('type="datetime-local"', "s zone (UTC-07:00).")
    end

    it "offers a closed set as a choice, and a record by its title with the key it stores", :aggregate_failures do
      expect(html).to include('<option value="shrub">Shrub</option>', '<option value="herb-spiral">The herb spiral</option>')
      expect(html).to include('<option value="ana">Ana Ruiz</option>')
    end

    it "writes a long text in a box" do
      expect(html).to include('<textarea class="textarea w-full max-w-3xl"')
    end
  end

  describe "a moment held as text", if: EditorNode.available? do
    it "is shown as the clock of its zone, and keeps the text it was held as", :aggregate_failures do
      html = result("reviseThyme")

      expect(html).to include('value="2026-11-07T10:00"', 'name="sown_on.value__held" value="2026-11-07T17:00:00.000Z"')
    end

    it "is sent exactly as it was held when the time shown is not changed" do
      sent = result("untouched").first["with"]

      held = [{ "value" => "2026-11-07T17:00:00.000Z" }, "2026-11-08T17:30:00.000Z"]
      expect([sent["sown_on"], sent["visits"].first["at"]]).to eq(held)
    end

    it "is written with the zone's offset when it is changed" do
      expect(result("changed").first["with"]["sown_on"]).to eq("value" => "2026-11-07T11:00:00-07:00")
    end

    it "is read from the clock of the zone when it is new", :aggregate_failures do
      sent = result("made")["sent"].first["with"]

      expect(sent["sown_on"]).to eq("value" => "2026-11-07T10:00:00-07:00")
      expect(sent["visits"]).to eq([{ "at" => "2026-11-09T08:15:00-07:00", "note" => "Sprouting" }])
    end
  end

  describe "an address left blank" do
    it "is made from the name, and the command is sent as the role it declares", :aggregate_failures do
      made = result("made")

      expect(made["sent"].first).to include("verb" => "Garden::Plant.Sow", "role" => "Editor")
      expect(made["sent"].first["with"]["slug"]).to eq("value" => "sweet-basil")
      expect([made["status"], made["location"]]).to eq([303, "/editor/Plant/id/sweet-basil"])
    end

    it "is made from the key for the parts of a note, with the time of the request", :aggregate_failures do
      sent = result("noteMade").first["with"]

      expect(sent["kind"]).to eq("value" => "plant")
      expect(sent["address"]).to eq("value" => "oak")
      expect(sent["written_at"]["value"]).to eq(1_800_000_000)
    end
  end

  describe "a note that goes with a record" do
    it "is shown on the page of the plant it belongs to, by the key the row makes", :aggregate_failures do
      html = result("detailThyme")

      expect(html).to include("Notes", "Pinch the tips.", "Seen by visitors.")
      expect(html).to include("/editor/Note/id/plant.thyme.note/Rewrite")
    end

    it "is the other row's key, when the record meets its `when`", :aggregate_failures do
      html = result("detailOak")

      expect(html).to include("No notes written for this plant yet.")
      expect(html).to include("/editor/Note/new/Write?slug.value=tree.oak.note")
    end

    it "is made on a form that asks for the words alone, the keys and the time behind more options", :aggregate_failures do
      html = result("noteForm")

      expect(html).to include("Words", "Plain sentences.", "More options")
      expect(html).not_to include("Save and add another")
    end
  end

  describe "a preview of the record on the site" do
    it "is a link to the site's page that opens in a new tab, when the row says it is not framed", :aggregate_failures do
      html = result("detailThyme")

      expect(html).to include('href="/plants/thyme" target="_blank" rel="noopener"', "View on the site")
      expect(html).not_to include("data-preview-frame")
    end

    it "is offered only for the aggregates a row gives an address for" do
      expect(result("noPreview")).not_to include("View on the site")
    end

    it "names no frame in the content security policy, since none is shown" do
      expect(files.fetch("src/app.ts")).not_to include("frame-src")
    end
  end

  describe "the list of plants" do
    it "names each by its name, with its address under it" do
      expect(result("list")).to include('>Thyme</a><span class="block text-xs text-muted">thyme</span>')
    end
  end

  describe "a refusal" do
    it "is the field's label and the rule, not the domain's type", :aggregate_failures do
      html = result("refused")["html"]

      expect(html).to include("Name: a plant has a name.")
      expect(result("refused")["status"]).to eq(422)
    end

    it "says a missing part is needed, in the field's words", :aggregate_failures do
      expect(result("shape")).to include("Visits: At is needed.")
    end
  end

  describe "an address that cannot be made" do
    it "asks for what it is made from, in that field's words, and sends nothing", :aggregate_failures do
      expect(result("blankName")).to include("Name is needed.")
      expect(result("blankName")).not_to include("was not given")
    end
  end

  describe "an account that is not an editor" do
    it "is told so on a page of the editor, with a way to go on, not a bare line", :aggregate_failures do
      expect(result("notFound")).to eq(401)
      expect(result("notFoundText")).to include("You cannot sign in here", "Sign in again from the site")
    end
  end
end
