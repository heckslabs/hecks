require "spec_helper"
require "json"
require "hecks/tools"
require "hecks/tools/site_routes"
require_relative "support/editor_node"

# The editor's working-desk parts, run under node against the stand-in host and a stand-in content
# system: the runner that does a scheduled action when it comes due and reports back, the list of
# what was changed through the editor and the putting back of a change, the library of what is
# uploaded and where it is used, the people screen and its refusals, the editor's own sign-in page,
# and the approximate preview that sends nothing to the domain.
STAGE2_SCENARIO = <<~JS.freeze
  import { accountToken } from "@hecks/client";
  import { mkdirSync, writeFileSync, rmSync } from "node:fs";
  import { tmpdir } from "node:os";
  import { join } from "node:path";

  const HISTORY = join(tmpdir(), `stage2-history-${process.pid}.jsonl`);
  rmSync(HISTORY, { force: true });
  process.env.EDITOR_HISTORY_FILE = HISTORY;

  const { createApp } = await import("./editor/src/app.ts");
  const { SCHEMA } = await import("./editor/src/schema.ts");
  const { runDue } = await import("./editor/src/runner.ts");
  const { hostClient } = await import("./editor/src/host.ts");
  const { entriesFor, forgetHistory } = await import("./editor/src/history.ts");
  const { standInHost } = await import("./host.mjs");

  const SECRET = "scenario-secret";
  const now = 1_800_000_000;
  const value = (text) => ({ value: text });
  const action = (id, subject, name, due) => ({ id: value(id), subject: value(subject), action: value(name), due_at: value(due), status: "pending" });
  const instances = {
    "Publishing::Post#first-light": { slug: value("first-light"), title: value("First light"), status: "draft" },
    "Publishing::Post#second-wind": { slug: value("second-wind"), title: value("Second wind"), status: "published" },
    "Publishing::Post#third-tide": { slug: value("third-tide"), title: value("Third tide"), status: "published", photo: "/files/api/media/file/door.png" },
    "People::Person#ed@example.org": { email: value("ed@example.org"), name: value("Ed Editor"), role: value("Admin") },
    "Schedule::ScheduledAction#due-publish": action("due-publish", "post:first-light", "publish", now - 60),
    "Schedule::ScheduledAction#due-withdraw": action("due-withdraw", "post:second-wind", "withdraw", now - 30),
    "Schedule::ScheduledAction#not-yet": action("not-yet", "post:third-tide", "withdraw", now + 3600),
    "Schedule::ScheduledAction#lost": action("lost", "post:missing", "publish", now - 10),
    "Schedule::ScheduledAction#again": action("again", "post:second-wind", "publish", now - 5),
  };
  const host = standInHost(SCHEMA, { instances });
  const disabled = new Set();
  const people = () => [
    { email: "ed@example.org", name: "Ed Editor", role: "Admin", linked: true, disabled: false },
    { email: "pat@example.org", name: "Pat Writer", role: "Editor", linked: false, disabled: disabled.has("pat@example.org") },
  ];
  const peopleCalls = [];
  const docs = [
    { filename: "door.png", alt: "A red door", url: "/files/api/media/file/door.png", mimeType: "image/png", filesize: 2048, width: 640, height: 480, sizes: { thumbnail: { url: "/files/api/media/file/door-400x300.webp" } } },
    { filename: "gate.png", alt: "A blue gate", url: "/files/api/media/file/gate.png", mimeType: "image/png", filesize: 4096, width: 800, height: 600 },
  ];
  const asked = [];
  const fetch = async (url, init = {}) => {
    const u = new URL(url);
    if (u.host === "content.test") {
      asked.push(u.pathname + u.search);
      if (u.pathname === "/files/api/sso") return { ok: true, status: 302, headers: { getSetCookie: () => ["payload-token=abc; Path=/"] } };
      const q = u.searchParams.get("where[or][0][alt][like]");
      const found = q ? docs.filter((doc) => doc.alt.toLowerCase().includes(q.toLowerCase())) : docs;
      return { ok: true, status: 200, json: async () => ({ docs: found, page: 1, totalPages: 1, totalDocs: found.length }) };
    }
    if (u.pathname === "/accounts/me") return { ok: true, status: 200, json: async () => ({ email: "ed@example.org" }) };
    if (u.pathname === "/members") return { ok: true, status: 200, json: async () => people() };
    if (u.pathname === "/members/disable" || u.pathname === "/members/enable") {
      const email = JSON.parse(init.body).email;
      peopleCalls.push([u.pathname, email]);
      if (email === "ed@example.org") return { ok: false, status: 403, json: async () => ({}) };
      if (u.pathname === "/members/disable") disabled.add(email); else disabled.delete(email);
      return { ok: true, status: 200, json: async () => ({}) };
    }
    return host.fetch(url, init);
  };

  mkdirSync(`${import.meta.dirname}/editor/dist`, { recursive: true });
  writeFileSync(`${import.meta.dirname}/editor/dist/editor.css`, "body { margin: 0; }\\n");
  writeFileSync(`${import.meta.dirname}/editor/dist/editor.js`, "export {};\\n");
  const storage = { put: async () => {}, url: (key) => key, read: async () => null };
  const app = createApp({ fetch, secret: SECRET, url: "http://host.test", cms: "http://content.test", now: () => now * 1000, storage });
  const call = (path, init = {}) => app(new Request(`http://site.test${path}`, init));
  const form = { "Content-Type": "application/x-www-form-urlencoded", Origin: "http://site.test" };
  const token = accountToken(SECRET, "ed@example.org", 60, { now: () => now * 1000 });
  const cookie = (await call(`/editor/api/sso?token=${token}`)).headers.get("set-cookie").split(";")[0];
  const admin = (path, init = {}) => call(path, { ...init, headers: { cookie, ...(init.headers ?? {}) } });
  const post = (body) => ({ method: "POST", body, headers: form });
  const text = async (path) => (await admin(path)).text();
  const verbs = () => host.sent.filter((body) => body.verb).map((body) => body.verb);
  const out = {};

  // The runner.
  host.sent.length = 0;
  const reports = await runDue(hostClient({ url: "http://host.test", fetch }), now);
  out.reports = reports.map((report) => [report.id, report.outcome, report.message]);
  out.states = Object.fromEntries(Object.entries(host.instances).map(([key, row]) => [key.split("#")[1], row.status]));
  out.reasons = Object.fromEntries(Object.entries(host.instances).filter(([, row]) => row.reason).map(([key, row]) => [key.split("#")[1], row.reason.value]));
  out.runSent = verbs();
  host.sent.length = 0;
  out.again = (await runDue(hostClient({ url: "http://host.test", fetch }), now)).length;

  // History and restore.
  host.sent.length = 0;
  const edit = (title) => admin("/editor/Publishing/Post/id/third-tide/Rename", post(`title.value=${encodeURIComponent(title)}`));
  await edit("Third tide, revised");
  await edit("Third tide, revised again");
  forgetHistory();
  const entries = entriesFor([{ aggregate: "Publishing::Post", id: "third-tide" }]);
  out.history = entries.map((entry) => ({ by: entry.by, command: entry.command, before: entry.before?.title?.value, after: entry.after?.title?.value }));
  out.detail = await text("/editor/Publishing/Post/id/third-tide");
  const oldest = entries.at(-1);
  host.sent.length = 0;
  const restored = await admin("/editor/Publishing/Post/id/third-tide/restore", post(`__entry=${oldest.n}&__back=%2Feditor%2FPublishing%2FPost%2Fid%2Fthird-tide`));
  out.restore = { status: restored.status, location: restored.headers.get("location"), title: host.instances["Publishing::Post#third-tide"].title.value, sent: verbs() };
  forgetHistory();
  out.afterRestore = entriesFor([{ aggregate: "Publishing::Post", id: "third-tide" }]).map((entry) => [entry.command, entry.restores ? "restore" : ""]);
  const missing = await admin("/editor/Publishing/Post/id/third-tide/restore", post("__entry=nope"));
  out.restoreUnknown = { status: missing.status, flash: missing.headers.get("set-cookie") !== null };

  // The approximate preview sends nothing to the domain.
  host.sent.length = 0;
  const preview = await admin("/editor/Publishing/Post/id/second-wind/preview", post("__previewcmd=Rename&title.value=Words+not+saved"));
  out.preview = { status: preview.status, html: await preview.text(), sent: verbs(), title: host.instances["Publishing::Post#second-wind"].title.value };
  const previewMade = await admin("/editor/Publishing/Post/new/Compose/preview", post("__previewcmd=Compose&slug.value=fresh&title.value=A+fresh+one"));
  out.previewNew = { status: previewMade.status, html: await previewMade.text() };

  // The library.
  asked.length = 0;
  out.library = await text("/editor/library");
  out.libraryAsked = asked.slice();
  out.libraryData = await (await admin("/editor/library/data?collection=media&q=gate")).json();
  const nav = await text("/editor");

  // People.
  out.people = await text("/editor/people");
  host.sent.length = 0;
  const added = await admin("/editor/people/add", post("name=Rae+Reader&email=Rae%40Example.org&role=Editor"));
  out.added = { status: added.status, location: added.headers.get("location"), sent: host.sent.filter((body) => body.verb).map((body) => [body.verb, body.to ?? null, JSON.stringify(body.with)]) };
  const dup = await admin("/editor/people/add", post("name=Pat&email=pat%40example.org&role=Editor"));
  out.duplicate = { status: dup.status, html: await dup.text() };
  const badRole = await admin("/editor/people/add", post("name=Zed&email=zed%40example.org&role=Owner"));
  out.badRole = { status: badRole.status };
  const last = await admin("/editor/people/role", post("email=ed%40example.org&role=Editor"));
  out.lastAdmin = { status: last.status, html: await last.text() };
  const off = await admin("/editor/people/turn-off", post("email=pat%40example.org"));
  out.off = { status: off.status, calls: peopleCalls.slice() };
  out.afterOff = await text("/editor/people");
  const self = await admin("/editor/people/turn-off", post("email=ed%40example.org"));
  out.self = { status: self.status, html: await self.text() };

  // Sign-in page, landing and the person with no session.
  const anonymous = (path) => call(path);
  const home = await anonymous("/editor");
  out.signedOutHome = { status: home.status, location: home.headers.get("location") };
  const login = await anonymous("/editor/login");
  out.login = { status: login.status, html: await login.text() };
  const landing = await anonymous("/admin.html");
  out.landing = { status: landing.status, location: landing.headers.get("location") };
  const signedIn = await admin("/editor/login");
  out.loginSignedIn = { status: signedIn.status, location: signedIn.headers.get("location") };
  const signOut = await admin("/editor/logout", post(""));
  out.signOut = { status: signOut.status, location: signOut.headers.get("location"), cookies: signOut.headers.getSetCookie?.() ?? [signOut.headers.get("set-cookie")] };

  // Help.
  out.help = await text("/editor/help");
  out.nav = nav;

  console.log(JSON.stringify(out));
JS

RSpec.describe "the generated editor's working-desk parts, run by node" do
  let(:project) { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/editor_stage2") }

  def files
    projected = Hecks::Tools::SiteRoutes.projection(project, out: "/work/out", editor: "/work/editor")
    projected.select { |path, _| path.start_with?("/work/editor/") }.transform_keys { |path| path.delete_prefix("/work/editor/") }
  end

  def result
    @result ||= begin
      expect(EditorNode.available?).to be(true), "node must strip TypeScript types for the editor scenarios"
      host = File.read(File.join(InMemoryDomain::ROOT, "spec/support/editor_stand_in_host.mjs"))
      EditorNode.run(files, STAGE2_SCENARIO, extra: { "host.mjs" => host })
    end
  end

  describe "the runner" do
    it "does each due action through the record's own command and settles it", :aggregate_failures do
      expect(result["states"]).to include("first-light" => "published", "second-wind" => "withdrawn", "due-publish" => "done",
                                          "due-withdraw" => "done", "not-yet" => "pending")
      expect(result["runSent"]).to include("Publishing::Post.Publish", "Publishing::Post.Withdraw", "Schedule::ScheduledAction.Complete")
    end

    it "fails an action it cannot do, and says why in words", :aggregate_failures do
      expect(result["states"]["lost"]).to eq("failed")
      expect(result["reasons"]["lost"]).to include("no post called missing")
    end

    it "treats an action whose record is already as it wants as done, changing nothing", :aggregate_failures do
      expect(result["reports"].find do |report|
        report[0] == "again"
      end).to eq(["again", "failed", "It is withdrawn, so \"publish\" does not apply to it now."])
        .or eq(["again", "done", ""])
    end

    it "settles an action once: a second pass finds nothing waiting that is due" do
      expect(result["again"]).to eq(0)
    end
  end

  describe "history" do
    it "lists each change through the editor with the person, newest first", :aggregate_failures do
      expect(result["history"].map { |entry| entry["by"] }).to all(eq("ed@example.org"))
      expect(result["history"].map { |entry| entry["after"] }).to eq(["Third tide, revised again", "Third tide, revised"])
      expect(result["detail"]).to include("History", "Put it back as it was before", "ed@example.org", "through this editor")
    end

    it "puts a change back by sending the editing command the old values, and lists the restore", :aggregate_failures do
      expect(result["restore"]).to include("title" => "Third tide", "sent" => ["Publishing::Post.Rename"])
      expect(result["afterRestore"].first).to eq(%w[Rename restore])
    end

    it "refuses a restore of an entry it does not hold, politely" do
      expect(result["restoreUnknown"]["status"]).to eq(303)
    end
  end

  describe "the approximate preview" do
    it "draws what was typed, says it is approximate, and sends nothing to the domain", :aggregate_failures do
      preview = result["preview"]
      expect(preview["status"]).to eq(200)
      expect(preview["html"]).to include("Preview (approximate)", "Words not saved", "View on the live site")
      expect(preview["sent"].grep(/Rename/)).to be_empty
      expect(preview["title"]).to eq("Second wind")
    end

    it "previews a record that is not made yet" do
      expect(result["previewNew"]["html"]).to include("A fresh one", "not saved yet")
    end
  end

  describe "the library" do
    it "lists what the content system holds, with a small picture and where each is used", :aggregate_failures do
      expect(result["library"]).to include("A red door", "door.png", "Third tide", "A blue gate")
      expect(result["library"]).to include("/files/api/media/file/door-400x300.webp")
      expect(result["libraryAsked"].last).to include("/files/api/media", "limit=24")
    end

    it "searches by description or name" do
      expect(result["libraryData"]["items"].map { |item| item["filename"] }).to eq(["gate.png"])
    end
  end

  describe "people" do
    it "lists who may edit with role and status, in plain words", :aggregate_failures do
      expect(result["people"]).to include("Ed Editor", "Pat Writer", "Can sign in", "This is you.", "Add a person")
      expect(result["people"]).not_to include("Waiting for first sign-in")
    end

    it "adds a person with the aggregate's own commands" do
      expect(result["added"]["sent"].map(&:first)).to eq(["People::Person.Admit", "People::Person.GrantAccess"])
    end

    it "refuses a person already listed, a role that is not given here and the last administrator's demotion",
       :aggregate_failures do
      expect(result["duplicate"]["status"]).to eq(422)
      expect(result["duplicate"]["html"]).to include("already on the list")
      expect(result["badRole"]["status"]).to eq(422)
      expect(result["lastAdmin"]["html"]).to include("at least one administrator")
    end

    it "turns a person off through the host's own route and shows it", :aggregate_failures do
      expect(result["off"]["calls"]).to eq([["/members/disable", "pat@example.org"]])
      expect(result["afterOff"]).to include("Turned off")
      expect(result["self"]["html"]).to include("cannot turn off your own access")
    end
  end

  describe "sign-in" do
    it "sends a person with no session to the editor's own page, which starts the host's sign-in", :aggregate_failures do
      expect(result["signedOutHome"]).to include("status" => 302, "location" => "/editor/login")
      expect(result["login"]["html"]).to include("Sign in with Google", 'href="/auth/google"')
    end

    it "takes the host's landing path to the editor, and a signed-in person past the page", :aggregate_failures do
      expect(result["landing"]).to include("status" => 303, "location" => "/editor")
      expect(result["loginSignedIn"]).to include("status" => 303, "location" => "/editor")
    end

    it "signs out of the site's own cookie too, so the next visit does not walk straight back in", :aggregate_failures do
      expect(result["signOut"]["location"]).to eq("/editor/login?note=signed-out")
      expect(result["signOut"]["cookies"].join).to include("newsroom_session=; Max-Age=0")
    end
  end

  describe "help and the navigation" do
    it "has a help page with a section for each job", :aggregate_failures do
      expect(result["help"]).to include("Help", "Posts", "History and putting a change back", "Previewing")
      expect(result["nav"]).to include("People", "Pictures and files", "Help")
    end
  end
end
