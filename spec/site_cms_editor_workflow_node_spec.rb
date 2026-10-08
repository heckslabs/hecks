require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "hecks/tools"
require "hecks/tools/site_routes"
require_relative "support/editor_node"

# The editor working on a post or a page as one thing, run under node against a stand-in host: the
# records that go with a record (a document, pictures, search wording), the actions scheduled for it,
# its preview, and the draft its body is written as. The stand-in host
# (spec/support/editor_stand_in_host.mjs) keeps the instances of five chapters that refer to each other only by
# `<kind>:<slug>` keys; each request the editor sends it is recorded in `sent`.
EDITOR_WORKFLOW_SCENARIO = <<~JS.freeze
  import { accountToken } from "@hecks/client";
  import { mkdirSync, writeFileSync } from "node:fs";
  import { createApp } from "./editor/src/app.ts";
  import { SCHEMA } from "./editor/src/schema.ts";
  import { standInHost, seed } from "./host.mjs";

  const SECRET = "scenario-secret";
  const now = 1_800_000_000;
  const host = standInHost(SCHEMA, { instances: seed(now) });
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
  const text = async (path) => (await admin(path)).text();
  const verbs = () => host.sent.filter((body) => body.verb);
  const back = (path) => encodeURIComponent(path);
  const POST = "/editor/Publishing/Post/id";
  const out = {};

  host.sent.length = 0;
  const first = await admin(`${POST}/first-light`);
  out.csp = first.headers.get("content-security-policy");
  out.first = await first.text();
  out.firstSent = host.sent.map((body) => body.read ? "read" : (body.query ?? body.verb));
  out.firstQuery = host.sent.find((body) => body.query);
  out.second = await text(`${POST}/second-wind`);
  out.page = await text("/editor/Publishing/Page/id/about");
  out.rename = await text(`${POST}/second-wind/Rename`);

  const here = `${POST}/second-wind`;
  out.addWording = await text(`/editor/Discovery/SearchWording/new/Describe?key.value=post%3Asecond-wind&_back=${back(here)}`);
  host.sent.length = 0;
  const described = await admin("/editor/Discovery/SearchWording/new/Describe", post(`key.value=post%3Asecond-wind&title.value=Second+wind&__back=${back(here)}`));
  out.described = { status: described.status, location: described.headers.get("location"), flash: described.headers.get("set-cookie"), sent: verbs() };
  host.refuseNext("Describe", "the title is taken");
  const refusedWording = await admin("/editor/Discovery/SearchWording/new/Describe", post(`key.value=post%3Afirst-light&title.value=Taken&__back=${back(`${POST}/first-light`)}`));
  out.refusedWording = { status: refusedWording.status, html: await refusedWording.text() };
  const elsewhere = await admin("/editor/Discovery/SearchWording/new/Describe", post("key.value=page%3Aabout&title.value=About&__back=https%3A%2F%2Fevil.test%2Fx"));
  out.elsewhere = { status: elsewhere.status, location: elsewhere.headers.get("location") };
  const sneaky = await admin("/editor/Discovery/SearchWording/new/Describe", post("key.value=page%3Aabout&title.value=About+again&__back=%2F%2Fevil.test%2Fx"));
  out.sneaky = { status: sneaky.status, location: sneaky.headers.get("location") };
  out.badBackPage = await text("/editor/Discovery/SearchWording/new/Describe?_back=https%3A%2F%2Fevil.test");
  out.secondAfter = await text(here);

  out.addPictures = await text(`/editor/Pictures/Gallery/new/Gather?key.value=post%3Afirst-light&_back=${back(`${POST}/first-light`)}`);
  await admin("/editor/Pictures/Gallery/new/Gather", post(`key.value=post%3Afirst-light&pictures.0.value=bb.png&pictures.1.value=aa.png&__back=${back(`${POST}/first-light`)}`));
  out.firstAfter = await text(`${POST}/first-light`);
  out.editPictures = await text(`/editor/Pictures/Gallery/id/post%3Afirst-light/Rearrange?_back=${back(`${POST}/first-light`)}`);

  out.scheduleBefore = await text(here);
  host.sent.length = 0;
  const due = now + 86_400;
  const added = await admin("/editor/Schedule/ScheduledAction/new/Schedule", post(`subject.value=post%3Asecond-wind&action.value=withdraw&due_at.value=${due}&__back=${back(here)}`));
  out.added = { status: added.status, location: added.headers.get("location"), sent: verbs() };
  host.sent.length = 0;
  const noAction = await admin("/editor/Schedule/ScheduledAction/new/Schedule", post(`subject.value=post%3Asecond-wind&action.value=erase&due_at.value=${due}&__back=${back(here)}`));
  out.noAction = { status: noAction.status, html: await noAction.text(), sent: verbs().length };
  out.scheduleAfter = await text(here);
  out.scheduled = await text("/editor/scheduled");
  const pending = Object.keys(host.instances).filter((key) => key.startsWith("Schedule::ScheduledAction#") && host.instances[key].subject.value === "post:second-wind" && host.instances[key].action.value === "withdraw");
  const madeId = pending[0].split("#")[1];
  out.madeId = madeId;
  out.reschedulePage = await text(`/editor/Schedule/ScheduledAction/id/${madeId}/Reschedule?_back=${back(here)}`);
  const cancelled = await admin(`/editor/Schedule/ScheduledAction/id/${madeId}/Cancel`, post(`__back=${back(here)}`));
  out.cancelled = { status: cancelled.status, location: cancelled.headers.get("location"), state: host.instances[pending[0]].status };
  out.afterCancel = await text(here);
  out.cancelPage = await text(`/editor/Schedule/ScheduledAction/id/${madeId}/Cancel?_back=${back(here)}`);
  out.scheduledEmpty = await text("/editor/scheduled");
  out.home = await text("/editor");

  const doc = "/editor/Documents/Document/id/post%3Afirst-light";
  out.draftPage = await text(`${doc}/SaveDraft?_back=${back(`${POST}/first-light`)}`);
  const body = (word) => `draft_body.blocks.0.kind=paragraph&draft_body.blocks.0.spans.0.text=${word}`;
  host.sent.length = 0;
  const saved = await admin(`${doc}/SaveDraft`, post(`${body("Hello")}&__back=${back(`${POST}/first-light`)}`, { "x-editor-autosave": "1" }));
  out.autosaved = { status: saved.status, text: await saved.text(), type: saved.headers.get("content-type"), sent: verbs().map((sent) => sent.verb) };
  out.liveAfterAutosave = host.instances["Documents::Document#post:first-light"].body.blocks.length;
  out.draftAfterAutosave = host.instances["Documents::Document#post:first-light"].draft_body.blocks[0].spans[0].text;
  host.sent.length = 0;
  const live = await admin(`${doc}/PublishDraft`, post("", { "x-editor-autosave": "1" }));
  out.autosaveRefused = { status: live.status, text: await live.text(), sent: verbs().length };
  host.refuseNext("SaveDraft", "the draft is too large");
  const failed = await admin(`${doc}/SaveDraft`, post(body("Again"), { "x-editor-autosave": "1" }));
  out.autosaveFailed = { status: failed.status, text: await failed.text() };
  const retried = await admin(`${doc}/SaveDraft`, post(body("Again"), { "x-editor-autosave": "1" }));
  out.autosaveRetried = { status: retried.status, text: await retried.text() };
  out.draftPageAfter = await text(`${doc}/SaveDraft?_back=${back(`${POST}/first-light`)}`);
  out.firstWithDraft = await text(`${POST}/first-light`);
  const published = await admin(`${doc}/PublishDraft`, post(`__back=${back(`${POST}/first-light`)}`));
  out.published = { status: published.status, location: published.headers.get("location"), live: host.instances["Documents::Document#post:first-light"].body.blocks[0].spans[0].text, draft: "draft_body" in host.instances["Documents::Document#post:first-light"] };
  await admin(`${doc}/SaveDraft`, post(body("Throwaway"), { "x-editor-autosave": "1" }));
  const discarded = await admin(`${doc}/DiscardDraft`, post(`__back=${back(`${POST}/first-light`)}`));
  out.discarded = { status: discarded.status, draft: "draft_body" in host.instances["Documents::Document#post:first-light"] };
  out.plainSave = (await admin(`${doc}/SaveDraft`, post(body("Plain")))).status;

  console.log(JSON.stringify(out));
JS

RSpec.describe "the generated workflow editor, run by node" do
  let(:project) { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/editor_workflow") }

  def files
    projected = Hecks::Tools::SiteRoutes.projection(project, out: "/work/out", editor: "/work/editor")
    projected.select { |path, _| path.start_with?("/work/editor/") }.transform_keys { |path| path.delete_prefix("/work/editor/") }
  end

  def run
    skip "node cannot strip TypeScript types here" unless EditorNode.available?

    host = File.read(File.join(InMemoryDomain::ROOT, "spec/support/editor_stand_in_host.mjs"))
    @run ||= EditorNode.run(files, EDITOR_WORKFLOW_SCENARIO, extra: { "host.mjs" => host })
  end

  def result(key) = run.fetch(key)

  # The section of a page that starts at `marker`, up to the end of its section element.
  def section(html, marker)
    start = html.index(marker) or raise "no #{marker} on the page"
    html[start..html.index("</section>", start)]
  end

  describe "the panels of the records that go with a record" do
    it "shows one panel for each aggregate keyed by the record, and none for the others", :aggregate_failures do
      html = result("first")

      expect(html.scan(/aria-labelledby="related-\d"/).size).to eq(3)
      expect(result("page")).to include("Add search wording")
      expect(result("home")).not_to include("related-0")
    end

    it "shows a document as read-only text with a link that edits its draft, and a way back", :aggregate_failures do
      panel = section(result("first"), 'aria-labelledby="related-0"')

      expect(panel).to include("The first post says hello.", "It has two paragraphs.")
      expect(panel).to include("/editor/Documents/Document/id/post%3Afirst-light/SaveDraft?_back=%2Feditor%2FPublishing")
    end

    it "offers to make a record that is not there, with the key already filled and the way back kept", :aggregate_failures do
      panel = section(result("second"), 'aria-labelledby="related-2"')

      expect(panel).to include("No search wording for this post yet.", "Add search wording")
      expect(panel).to include("/editor/Discovery/SearchWording/new/Describe?key.value=post%3Asecond-wind&#38;_back=")
    end

    it "names the key by the kind of the record, a page's by `page`", :aggregate_failures do
      expect(result("page")).to include("key.value=page%3Aabout")
      expect(result("page")).to include("/editor/Pictures/Gallery/new/Gather?key.value=page%3Aabout")
    end

    it "fills the form of the related aggregate from the address and links back to the record", :aggregate_failures do
      form = result("addWording")

      expect(form).to include('name="key.value" value="post:second-wind"', ">Back to second-wind</a>")
      expect(form).to include('<input type="hidden" name="__back" value="/editor/Publishing/Post/id/second-wind">')
    end

    it "returns to the record after the save, with a notice, and shows the record it made", :aggregate_failures do
      described = result("described")

      expect(described).to include("status" => 303, "location" => "/editor/Publishing/Post/id/second-wind")
      expect(described["flash"]).to start_with("newsroom_editor_flash=")
      expect(section(result("secondAfter"), 'aria-labelledby="related-2"')).to include("Edit", "Title")
    end

    it "keeps the way back when the domain refuses the save", :aggregate_failures do
      refused = result("refusedWording")

      expect(refused["status"]).to eq(422)
      expect(refused["html"]).to include('name="__back" value="/editor/Publishing/Post/id/first-light"', "the title is taken")
    end

    it "follows a way back only when it is a page of the editor", :aggregate_failures do
      expect(result("elsewhere")).to include("status" => 303, "location" => "/editor/Discovery/SearchWording/id/page%3Aabout")
      expect(result("sneaky")["location"]).to eq("/editor/Discovery/SearchWording/id/page%3Aabout")
      expect(result("badBackPage")).not_to include("Back to", "evil.test")
    end

    it "shows pictures as a strip of thumbnails in their order, each with its alt text", :aggregate_failures do
      strip = section(result("firstAfter"), 'aria-labelledby="related-1"')

      expect(strip.scan(%r{src="/editor/media/([^"]+)"}).flatten).to eq(%w[bb.png aa.png])
      expect(strip).to include('alt="A blue gate"', 'alt="A red door"', "Picture 2 of 2")
    end

    it "edits the pictures on their own form, filled from the gallery", :aggregate_failures do
      expect(result("editPictures")).to include("Back to first-light", 'name="pictures.0.value" value="bb.png"')
      expect(result("addPictures")).to include('name="key.value" value="post:first-light"')
    end

    it "says a document has changes that are not published when it holds a draft" do
      expect(section(result("firstWithDraft"), 'aria-labelledby="related-0"')).to include("Changes not published yet")
    end

    it "reads the domain once for a record's page, and asks the scheduling query for its actions", :aggregate_failures do
      expect(result("firstSent")).to eq(["read", "Schedule::ScheduledAction.ForSubject"])
      expect(result("firstQuery")["args"]).to eq("subject" => { "value" => "post:first-light" })
    end
  end

  describe "the schedule" do
    it "lists the pending actions of a record, soonest first, with the time in the viewer's zone", :aggregate_failures do
      panel = section(result("scheduleAfter"), 'aria-labelledby="schedule-title"')

      expect(panel).to include('data-moment="datetime"', "Pending actions", "Reschedule")
      expect(panel.index("Withdraw")).to be < panel.index(">Publish<")
    end

    it "says it only saves the actions, and never publishes anything itself" do
      expect(result("first")).to include("run later, at the time you choose, by something outside this editor")
    end

    it "adds an action with the action chosen from the closed set and the due time a datetime input", :aggregate_failures do
      form = section(result("first"), 'aria-labelledby="schedule-title"')

      expect(form).to include('<select class="select w-full max-w-xl" id="f-action-value" name="action.value"')
      expect(form).to include('<option value="withdraw">Withdraw</option>', 'data-moment-field="datetime"', 'name="due_at.value"')
    end

    it "makes the identity of the action itself, and sends the subject from the page", :aggregate_failures do
      sent = result("added")["sent"].first["with"]

      expect(result("first")).not_to include('name="id.value"')
      expect(sent.keys).to eq(%w[subject action due_at id])
      expect(sent["id"]["value"]).to match(/\A\h{8}(-\h{4}){3}-\h{12}\z/)
    end

    it "returns to the record after adding one", :aggregate_failures do
      expect(result("added")).to include("status" => 303, "location" => "/editor/Publishing/Post/id/second-wind")
      expect(result("scheduleAfter")).to include(result("madeId"))
    end

    it "refuses an action that is not one of the closed set before anything is sent", :aggregate_failures do
      refused = result("noAction")

      expect(refused["status"]).to eq(422)
      expect(refused["html"]).to include("Choose one of publish, withdraw.", 'aria-invalid="true"')
      expect(refused["sent"]).to eq(0)
    end

    it "changes a time on the action's own form, and asks first before cancelling, in a dialog", :aggregate_failures do
      panel = section(result("scheduleAfter"), 'aria-labelledby="schedule-title"')

      expect(result("reschedulePage")).to include("Back to second-wind", 'name="due_at.value"', 'value="1800086400"')
      expect(panel).to include('data-confirm="confirm-Cancel-0"', '<dialog class="modal" id="confirm-Cancel-0"',
                               ">Go back</button>")
    end

    it "cancels from the dialog and goes back to the record, which then shows the action as ended", :aggregate_failures do
      expect(result("cancelled")).to include("status" => 303, "state" => "cancelled",
                                             "location" => "/editor/Publishing/Post/id/second-wind")
      expect(section(result("afterCancel"), 'aria-labelledby="schedule-title"')).to include("Earlier", "Cancelled")
    end

    it "shows an ended action with its outcome, and the reason a failed one gives", :aggregate_failures do
      earlier = result("first")[%r{Earlier.*?</ul>}m]

      expect(earlier).to include("Done", "Failed", "The site did not answer.")
    end

    it "has a screen of the pending actions of every record, soonest first, linking to each record", :aggregate_failures do
      screen = result("scheduled")

      expect(screen).to include("<title>Scheduled - Newsroom editor</title>", 'href="/editor/Publishing/Post/id/second-wind"')
      times = screen.scan(/data-epoch="(\d+)"/).flatten.map(&:to_i)
      expect(times).to eq(times.sort)
    end

    it "lists the screen in the navigation, and leaves ended actions off it", :aggregate_failures do
      expect(result("first")).to include('<li><a href="/editor/scheduled"><span class="truncate">Scheduled</span></a></li>')
      expect(result("scheduledEmpty")).to include("a1")
    end
  end

  describe "the preview" do
    it "offers a button on a record's page, and on the page of a command that edits it", :aggregate_failures do
      expect(result("first")).to include('data-preview-open="preview-toggle"')
      expect(result("rename")).to include('data-preview-open="preview-toggle"')
    end

    it "fills the address from the record's key: its kind, its slug and its key", :aggregate_failures do
      expect(result("first")).to include('data-src="https://site.example.com/post/first-light?preview=1"')
      expect(result("page")).to include('data-src="https://site.example.com/page/about?preview=1"')
    end

    it "frames the address in a drawer, sandboxed to scripts and its own origin and nothing else", :aggregate_failures do
      drawer = section(result("first"), 'class="drawer drawer-end"')

      expect(drawer).to include('sandbox="allow-scripts allow-same-origin"', "data-preview-width=\"phone\"",
                                "data-preview-width=\"tablet\"")
      expect(drawer).to include("data-preview-refresh", 'target="_blank" rel="noopener" data-preview-external')
    end

    it "adds the preview's origin to the policy as the only frame source, and nothing else", :aggregate_failures do
      policy = result("csp")

      expect(policy).to include("frame-src https://site.example.com;")
      expect(policy.sub("frame-src https://site.example.com; ", "")).to eq(default_policy)
    end

    def default_policy
      "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; connect-src 'self'; " \
        "form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
    end
  end

  describe "a draft written as the person types" do
    it "puts the body editor of the draft-saving command in draft mode, with a status line", :aggregate_failures do
      page = result("draftPage")

      expect(page).to include('data-draft="draft_body"', "data-body-editor data-draft", "data-draft-status")
      expect(page).to include("No draft is saved yet. The live body changes only when the draft is published.")
    end

    it "pairs publishing and discarding the draft, each behind a dialog, publishing saving first", :aggregate_failures do
      page = result("draftPage")

      expect(page).to include('data-confirm="confirm-PublishDraft"', 'data-confirm="confirm-DiscardDraft"',
                              "PublishDraft\" data-flush-draft>")
      expect(page).to include("hidden data-draft-discard")
    end

    it "shows the discard button when a draft is already saved" do
      expect(result("draftPageAfter")).not_to include("hidden data-draft-discard")
    end

    it "saves the draft by a form post answered in plain text, and never touches the live body", :aggregate_failures do
      saved = result("autosaved")

      expect(saved).to include("status" => 200, "text" => "Saved.", "sent" => ["Documents::Document.SaveDraft"])
      expect(result("draftAfterAutosave")).to eq("Hello")
      expect(result("liveAfterAutosave")).to eq(2)
    end

    it "only ever runs the draft-saving command this way", :aggregate_failures do
      expect(result("autosaveRefused")).to include("status" => 400, "sent" => 0)
    end

    it "answers a refused save with its reason, and a retry with the same form saves", :aggregate_failures do
      expect(result("autosaveFailed")).to include("status" => 422, "text" => "Not allowed unless the draft is too large.")
      expect(result("autosaveRetried")).to include("status" => 200, "text" => "Saved.")
    end

    it "publishes the draft into the live body and goes back to the record", :aggregate_failures do
      expect(result("published")).to include("status" => 303, "live" => "Again", "draft" => false)
      expect(result("published")["location"]).to eq("/editor/Publishing/Post/id/first-light")
    end

    it "discards the draft, and a plain save of the form still redirects", :aggregate_failures do
      expect(result("discarded")).to include("status" => 303, "draft" => false)
      expect(result("plainSave")).to eq(303)
    end
  end
end
