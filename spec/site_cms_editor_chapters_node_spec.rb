require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "hecks/tools"
require "hecks/tools/site_routes"
require_relative "support/editor_node"

# The multi-chapter editor, run under node against a fake host: its navigation, its roles, the
# pickers and the checks on what they name, the lists a page at a time, the moments, and the forms.
# The fake host answers `/members` and the body-shaped `/dispatch`, keeping the instances of both
# chapters; each request it is sent is recorded in `sent`.
EDITOR_CHAPTERS_SCENARIO = <<~JS.freeze
  import { accountToken } from "@hecks/client";
  import { mkdirSync, writeFileSync } from "node:fs";
  import { createApp } from "./editor/src/app.ts";

  const SECRET = "scenario-secret";
  const clock = 1_800_000_000_000;
  const members = [{ email: "ed@example.org", role: "Admin" }, { email: "own@example.org", role: "Owner" }];
  let sent = [];
  const v = (value) => ({ value });
  const base = 1_790_000_000;
  const article = (slug, title, status, categories = []) => [
    `Press::Article#${slug}`,
    { slug: v(slug), title: v(title), published_on: v(base), categories: categories.map(v), status },
  ];
  const instances = Object.fromEntries([
    article("alpha", "Alpha harvest", "published", ["news"]),
    article("bravo", "Bravo morning", "draft", ["news"]),
    article("charlie", "Charlie evening", "published"),
    article("delta", "Delta delayed", "draft"),
    article("echo", "Echo afternoon", "archived"),
    article("foxtrot", "Foxtrot finale", "draft", ["opinion"]),
    ["Press::Category#news", { slug: v("news"), name: v("News"), status: "active" }],
    ["Press::Category#guides", { slug: v("guides"), name: v("Guides"), status: "active" }],
    ["Press::Category#opinion", { slug: v("opinion"), name: v("Opinion"), status: "retired" }],
    ["Press::Note#n1", { key: v("n1"), text: v("Call"), remind_at: v(base) }],
    ["Library::MediaItem#aa.png", { key: v("aa.png"), alt: v("A red door"), mime_type: v("image/png") }],
    ["Library::Category#news", { slug: v("news"), name: v("News photos") }],
    ["Library::Gallery#article:alpha", { key: v("article:alpha"), name: v("Alpha pictures"), pictures: [v("aa.png")] }],
  ]);
  const answer = (extra = {}) => ({ ok: true, status: 200, json: async () => ({ instances: structuredClone(instances), refusals: [], ...extra }) });
  const fetch = async (url, init) => {
    if (new URL(url).pathname === "/members") return { ok: true, status: 200, json: async () => members };
    const body = JSON.parse(init.body);
    sent.push(body);
    if (body.read) return answer();
    if (body.query) {
      const [domain, rest] = body.query.split("::");
      const [aggregate, query] = rest.split(".");
      let rows = Object.entries(instances).filter(([id]) => id.startsWith(`${domain}::${aggregate}#`)).map(([, row]) => row);
      if (query === "Active") rows = rows.filter((row) => row.status === "active");
      if (query === "Published") rows = rows.filter((row) => row.status === "published");
      return answer({ queries: [{ query: body.query, rows }] });
    }
    const [domain, rest] = body.verb.split("::");
    const [aggregate, verb] = rest.split(".");
    if (body.to) {
      if (verb === "Publish") instances[`${domain}::${aggregate}#${body.to}`].status = "published";
      else Object.assign(instances[`${domain}::${aggregate}#${body.to}`], body.with);
    } else {
      const identity = { Article: "slug", Category: "slug", Note: "key", Gallery: "key", MediaItem: "key" }[aggregate];
      const state = { ...body.with, ...(aggregate === "Article" ? { status: "draft" } : {}) };
      instances[`${domain}::${aggregate}#${Object.values(state[identity])[0]}`] = state;
    }
    return answer();
  };

  mkdirSync(`${import.meta.dirname}/editor/dist`, { recursive: true });
  writeFileSync(`${import.meta.dirname}/editor/dist/editor.css`, "body { margin: 0; }\\n");
  writeFileSync(`${import.meta.dirname}/editor/dist/editor.js`, "export {};\\n");

  const app = createApp({ fetch, secret: SECRET, url: "http://host.test", now: () => clock, storage: { put: async () => {}, url: (key) => key, read: async () => null } });
  const form = { "Content-Type": "application/x-www-form-urlencoded", Origin: "http://site.test" };
  const call = (path, init = {}) => app(new Request(`http://site.test${path}`, init));
  const signIn = async (email) => (await call(`/editor/api/sso?token=${accountToken(SECRET, email, 60, { now: () => clock })}`)).headers.get("set-cookie")?.split(";")[0];
  const as = (cookie) => (path, init = {}) => call(path, { ...init, headers: { cookie, ...(init.headers ?? {}) } });
  const post = (body) => ({ method: "POST", body, headers: form });
  const verbs = () => sent.filter((body) => body.verb);
  const text = async (path, who) => (await who(path)).text();
  const out = {};

  const admin = as(await signIn("ed@example.org"));
  const owner = as(await signIn("own@example.org"));

  out.home = await text("/editor", admin);
  out.ownerHome = await text("/editor", owner);
  out.pressCategories = await text("/editor/Press/Category", admin);
  out.libraryCategories = await text("/editor/Library/Category", admin);
  out.noChapterPath = await admin("/editor/Article").then((r) => r.status);
  out.ownerGallery = await owner("/editor/Library/Gallery").then((r) => r.status);
  out.ownerPicture = await owner("/editor/media").then((r) => r.status);
  out.adminGallery = await admin("/editor/Library/Gallery").then((r) => r.status);

  sent = [];
  out.listPage = await text("/editor/Press/Article", admin);
  out.listReads = sent.filter((body) => body.read).length;
  out.pageTwo = await text("/editor/Press/Article?_page=2", admin);
  out.pageClamped = await text("/editor/Press/Article?_page=99", admin);
  out.pageJunk = await text("/editor/Press/Article?_page=abc", admin);
  out.drafts = await text("/editor/Press/Article?_status=draft", admin);
  out.draftsTwo = await text("/editor/Press/Article?_status=draft&_page=2", admin);
  out.badStatus = await text("/editor/Press/Article?_status=nonsense", admin);
  out.searchTitle = await text("/editor/Press/Article?_q=morning", admin);
  out.searchIdentity = await text("/editor/Press/Article?_q=ECHO", admin);
  out.searchNone = await text("/editor/Press/Article?_q=zzz", admin);
  out.searchAndStatus = await text("/editor/Press/Article?_q=a&_status=published", admin);
  out.viewPaged = await text("/editor/Press/Article?query=Published", admin);
  out.noteList = await text("/editor/Press/Note", admin);
  out.categoryList = await text("/editor/Press/Category", admin);

  sent = [];
  out.draftForm = await text("/editor/Press/Article/new/Draft", admin);
  out.draftAsked = sent.filter((body) => body.query);
  out.reviseForm = await text("/editor/Press/Article/id/foxtrot/Revise", admin);
  out.composeForm = await text("/editor/Library/Gallery/new/Compose", admin);

  const draft = (extra) => `slug.value=golf&title.value=Golf&published_on.value=1790000000${extra}`;
  sent = [];
  const missing = await admin("/editor/Press/Article/new/Draft", post(draft("&categories.0.value=nope")));
  out.missingCategory = { status: missing.status, html: await missing.text(), sent: verbs() };
  sent = [];
  const accepted = await admin("/editor/Press/Article/new/Draft", post(draft("&categories.0.value=news&categories.1.value=guides&cover.value=https%3A%2F%2Fx.test%2Fa.png")));
  out.acceptedCategory = { status: accepted.status, location: accepted.headers.get("location"), sent: verbs() };
  const again = await admin("/editor/Press/Article/new/Draft", post(`${draft("&categories.0.value=news").replace("golf", "hotel")}&__again=1`));
  out.again = { status: again.status, location: again.headers.get("location") };
  sent = [];
  const retired = await admin("/editor/Press/Article/id/foxtrot/Revise", post("title.value=Foxtrot+finale&published_on.value=1790000000&categories.0.value=opinion"));
  out.retiredKept = { status: retired.status, location: retired.headers.get("location"), sent: verbs() };

  sent = [];
  const badKey = await admin("/editor/Library/Gallery/new/Compose", post("key.value=article%3Azzz&name.value=Z"));
  out.galleryMissing = { status: badKey.status, html: await badKey.text(), sent: verbs() };
  const badKind = await admin("/editor/Library/Gallery/new/Compose", post("key.value=thing%3Ax&name.value=Z"));
  out.galleryKind = { status: badKind.status, html: await badKind.text() };
  sent = [];
  const okKey = await admin("/editor/Library/Gallery/new/Compose", post("key.value=article%3Abravo&name.value=B&pictures.0.value=aa.png"));
  out.galleryOk = { status: okKey.status, location: okKey.headers.get("location"), sent: verbs() };

  out.detail = await text("/editor/Press/Article/id/alpha", admin);
  out.noteDetail = await text("/editor/Press/Note/id/n1", admin);
  out.noteForm = await text("/editor/Press/Note/new/Jot", admin);
  out.title = await text("/editor/Press/Article/id/alpha", admin);

  console.log(JSON.stringify(out));
JS

# The moments' conversions, run under node in whatever zone `TZ` names.
EDITOR_EPOCH_SCENARIO = <<~JS.freeze
  import { formatMoment, fromLocal, relative, toLocal, zoneLabel } from "./editor/src/browser/epoch.js";

  const seconds = 1_789_999_980;
  const now = 1_790_000_000;
  const out = {
    datetime: toLocal(seconds, "datetime"),
    date: toLocal(seconds, "date"),
    zone: zoneLabel(seconds),
    roundTrip: fromLocal(toLocal(seconds, "datetime"), "datetime"),
    startOfDay: fromLocal(toLocal(seconds, "date"), "date"),
    impossible: fromLocal("2026-02-30", "date"),
    garbage: [fromLocal("", "date"), fromLocal(null, "datetime"), fromLocal("tomorrow", "date")],
    inThreeDays: relative(now + 3 * 86_400, now, "datetime"),
    hoursAgo: relative(now - 2 * 3_600, now, "datetime"),
    tomorrow: relative(now + 86_400, now, "date"),
    formatted: formatMoment(seconds, "datetime"),
  };
  console.log(JSON.stringify(out));
JS

# What each zone reads of 1789999980 (14:13 UTC on the 21st of September 2026): the date and time,
# the offset, and the seconds of the start of that local day.
EDITOR_ZONES = {
  "UTC"                 => ["2026-09-21T14:13", "UTC+00:00", 1_789_948_800],
  "America/Los_Angeles" => ["2026-09-21T07:13", "UTC-07:00", 1_789_974_000],
  "Asia/Kolkata"        => ["2026-09-21T19:43", "UTC+05:30", 1_789_929_000],
  "Pacific/Auckland"    => ["2026-09-22T02:13", "UTC+12:00", 1_789_992_000]
}.freeze

RSpec.describe "the generated multi-chapter editor, run by node" do
  let(:project) { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/editor_chapters") }

  def files
    projected = Hecks::Tools::SiteRoutes.projection(project, out: "/work/out", editor: "/work/editor")
    projected.select { |path, _| path.start_with?("/work/editor/") }.transform_keys { |path| path.delete_prefix("/work/editor/") }
  end

  def run
    skip "node cannot strip TypeScript types here" unless EditorNode.available?

    @run ||= EditorNode.run(files, EDITOR_CHAPTERS_SCENARIO)
  end

  def result(key) = run.fetch(key)

  def verbs_of(key) = result(key)["sent"].map { |body| body["verb"] }

  describe "the navigation" do
    it "groups the aggregates under a heading for each chapter, in the order the row gives them", :aggregate_failures do
      home = result("home")

      expect(home).to include('<li class="menu-title mt-4 px-3 text-muted">Press</li>',
                              '<li class="menu-title mt-4 px-3 text-muted">Library</li>')
      expect(home.index(">Press</li>")).to be < home.index(">Library</li>")
    end

    it "addresses each aggregate by its chapter and its name", :aggregate_failures do
      expect(result("home")).to include('href="/editor/Press/Article"', 'href="/editor/Library/Gallery"',
                                        'href="/editor/Library/Category"')
      expect(result("noChapterPath")).to eq(404)
    end

    it "shows the overview in groups as well, with the counts of each aggregate", :aggregate_failures do
      expect(result("home")).to include('<h2 class="mb-2 mt-8 text-lg">Press</h2>', '<h2 class="mb-2 mt-8 text-lg">Library</h2>')
      expect(result("home")).to include('tabular-nums text-muted">6</span>')
    end

    it "keeps two aggregates of one name apart, each listing its own instances", :aggregate_failures do
      expect(result("pressCategories")).to include("Guides", "<title>Categories (Press) - Press editor</title>")
      expect(result("libraryCategories")).to include("News photos")
      expect(result("libraryCategories")).not_to include("Guides")
    end

    it "marks only the page the person is on, by chapter and name", :aggregate_failures do
      expect(result("pressCategories")).to include('<a href="/editor/Press/Category" aria-current="page">')
      expect(result("pressCategories")).not_to include('<a href="/editor/Library/Category" aria-current="page">')
    end
  end

  describe "the roles of a chapter" do
    it "leaves a chapter out of the navigation and the overview for a role it is not open to", :aggregate_failures do
      expect(result("ownerHome")).to include('href="/editor/Press/Article"')
      expect(result("ownerHome")).not_to include("Library", "/editor/Library/")
    end

    it "refuses the pages of that chapter, and its pictures, to that role, and serves them to the others", :aggregate_failures do
      expect(result("ownerGallery")).to eq(403)
      expect(result("ownerPicture")).to eq(403)
      expect(result("adminGallery")).to eq(200)
    end
  end

  describe "a list at scale" do
    it "shows one page of rows, with the range and total, and links to the next page", :aggregate_failures do
      html = result("listPage")

      expect(html).to include("1–2 of 6 articles", "Page 1 of 3", 'href="/editor/Press/Article?_page=2"')
      expect(html).to include("alpha", "bravo")
      expect(html).not_to include("charlie")
    end

    it "asks the host for one read, which the page and the counts share" do
      expect(result("listReads")).to eq(1)
    end

    it "follows the page asked for, clamps one past the end, and takes nonsense for the first", :aggregate_failures do
      expect(result("pageTwo")).to include("charlie", "delta", "3–4 of 6", 'rel="prev"')
      expect(result("pageTwo")).not_to include("alpha")
      expect(result("pageClamped")).to include("Page 3 of 3", "foxtrot")
      expect(result("pageJunk")).to include("Page 1 of 3")
    end

    it "filters by a lifecycle state on the server, and keeps the filter on the links to other pages", :aggregate_failures do
      expect(result("drafts")).to include("1–2 of 3 articles match", "bravo", "delta")
      expect(result("drafts")).to include('href="/editor/Press/Article?_status=draft&#38;_page=2"')
      expect(result("draftsTwo")).to include("foxtrot")
      expect(result("draftsTwo")).not_to include("delta")
    end

    it "ignores a state the lifecycle does not have", :aggregate_failures do
      expect(result("badStatus")).to include("1–2 of 6 articles")
      expect(result("badStatus")).not_to include(" match")
    end

    it "searches the identity and the title, without regard to case", :aggregate_failures do
      expect(result("searchTitle")).to include("1 article match", "bravo")
      expect(result("searchIdentity")).to include("1 article match", "echo")
    end

    it "says nothing matches, keeping the search box, and combines a search with a state", :aggregate_failures do
      expect(result("searchNone")).to include("No articles match.", 'name="_q" value="zzz"')
      expect(result("searchAndStatus")).to include("2 articles match", "alpha", "charlie")
    end

    it "keeps the view of the domain's own query on every link", :aggregate_failures do
      html = result("viewPaged")

      expect(html).to include('name="query" value="Published"', "2 articles")
      expect(html).not_to include("Page 1 of")
    end

    it "offers the status filter only for an aggregate that has a lifecycle", :aggregate_failures do
      expect(result("listPage")).to include('name="_status"', "<option value=\"draft\">Draft</option>")
      expect(result("noteList")).not_to include('name="_status"')
    end
  end

  describe "the pickers" do
    it "offers a select of the categories the target's active query lists, and not a retired one", :aggregate_failures do
      form = result("draftForm")

      expect(form).to include('<select class="select w-full max-w-xl" id="f-categories-0-value" name="categories.0.value">')
      expect(form).to include('<option value="news">News (news)</option>')
      expect(form).not_to include('<option value="opinion">')
    end

    it "asks each target's own query, in its own chapter, for what to offer" do
      expect(result("draftAsked").map { |body| body["query"] }).to eq(["Press::Category.Active", "Library::MediaItem.Pictures"])
    end

    it "keeps a key the form already names that is no longer offered, saying so", :aggregate_failures do
      expect(result("reviseForm")).to include('<option value="opinion" selected>opinion (not on offer)</option>')
    end

    it "refuses a key the target does not hold before anything is sent, naming the field", :aggregate_failures do
      missing = result("missingCategory")

      expect(missing["status"]).to eq(422)
      expect(missing["html"]).to include("No category has the key &#34;nope&#34;.", 'aria-invalid="true"')
      expect(missing["sent"]).to be_empty
    end

    it "sends the command, with the keys in order, when each key is there", :aggregate_failures do
      accepted = result("acceptedCategory")

      expect(accepted["status"]).to eq(303)
      expect(accepted["sent"].map do |body|
        [body["verb"], body["with"]["categories"]]
      end).to eq([["Press::Article.Draft", [{ "value" => "news" }, { "value" => "guides" }]]])
    end

    it "accepts a key that is retired, since it exists", :aggregate_failures do
      expect(result("retiredKept")["status"]).to eq(303)
      expect(verbs_of("retiredKept")).to eq(["Press::Article.Revise"])
    end

    it "suggests pictures in a text box that accepts an address as well", :aggregate_failures do
      expect(result("draftForm")).to include('list="choices-Library-MediaItem"')
      expect(result("draftForm")).to include('<option value="aa.png" label="A red door (aa.png)">')
      expect(result("draftForm")).not_to include('list="choices-Library-MediaItem" autocomplete="off" data-strict')
    end

    it "gives a `<kind>:<key>` value its kinds, and for each the records of the aggregate it names", :aggregate_failures do
      form = result("composeForm")

      expect(form).to include("data-key-picker", "&#34;kind&#34;:&#34;article&#34;", "&#34;kind&#34;:&#34;note&#34;")
      expect(form).to include("&#34;key&#34;:&#34;alpha&#34;")
    end

    it "refuses a kind it does not have and a record that is not there", :aggregate_failures do
      expect(result("galleryKind")["html"]).to include("Start with one of article, note and a colon, as in article:key.")
      expect(result("galleryMissing")["html"]).to include("No article has the key &#34;zzz&#34;.")
      expect(result("galleryMissing")["sent"]).to be_empty
    end

    it "sends a gallery named for a record that is there, in the chapter that declares the gallery", :aggregate_failures do
      expect(result("galleryOk")["status"]).to eq(303)
      expect(verbs_of("galleryOk")).to eq(["Library::Gallery.Compose"])
    end
  end

  describe "dispatch" do
    it "names each verb with its chapter, so aggregates of one name are not confused", :aggregate_failures do
      expect(verbs_of("acceptedCategory")).to eq(["Press::Article.Draft"])
      expect(result("galleryOk")["location"]).to eq("/editor/Library/Gallery/id/article%3Abravo")
    end

    it "sends the person to the new instance's page, in its chapter" do
      expect(result("acceptedCategory")["location"]).to eq("/editor/Press/Article/id/golf")
    end
  end

  describe "save and add another" do
    it "is offered on a form that makes something, beside the command's own button", :aggregate_failures do
      button = '<button type="submit" class="btn" name="__again" value="1" data-busy>Save and add another</button>'
      expect(result("draftForm")).to include(button)
      expect(result("reviseForm")).not_to include("Save and add another")
    end

    it "starts the form again when it was the button pressed, and shows the new instance when it was not" do
      expect(result("again")["location"]).to eq("/editor/Press/Article/new/Draft")
    end
  end

  describe "moments" do
    it "gives a date a field that holds the seconds, which the script swaps for a native date input", :aggregate_failures do
      form = result("draftForm")

      expect(form).to include('data-moment-field="date"', 'name="published_on.value"', "data-epoch-raw")
      expect(result("noteForm")).to include('data-moment-field="datetime"', 'name="remind_at.value"')
    end

    it "shows a moment read-only in UTC, with the seconds for the script to restate", :aggregate_failures do
      element = '<time class="whitespace-nowrap" datetime="2026-09-21T14:13:20.000Z" data-moment="date" data-epoch="1790000000">'
      expect(result("detail")).to include("#{element}2026-09-21</time>")
      expect(result("noteDetail")).to include('data-moment="datetime" data-epoch="1790000000">2026-09-21 14:13 UTC</time>')
    end

    it "sorts a list's moments by their seconds, as numbers", :aggregate_failures do
      expect(result("listPage")).to include('<td data-value="1790000000"><time')
      expect(result("listPage")).to include('data-sort="number">Published on</th>')
    end
  end

  describe "the conversions of a moment, in several time zones" do
    def in_zone(zone)
      skip "node cannot strip TypeScript types here" unless EditorNode.available?

      EditorNode.run(files, EDITOR_EPOCH_SCENARIO, env: { "TZ" => zone, "LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8" })
    end

    EDITOR_ZONES.each do |zone, (local, offset, day)|
      it "reads and writes the same moment in #{zone}", :aggregate_failures do
        out = in_zone(zone)

        expect(out.values_at("datetime", "date")).to eq([local, local[0, 10]])
        expect(out.values_at("roundTrip", "startOfDay")).to eq([1_789_999_980, day])
        expect(out["zone"]).to end_with("(#{offset})")
      end
    end

    it "reads nothing from text that is not a date, or a day that is not there", :aggregate_failures do
      out = in_zone("UTC")

      expect(out["impossible"]).to be_nil
      expect(out["garbage"]).to eq([nil, nil, nil])
    end

    it "says how far a moment is, in words, for a time and for a day", :aggregate_failures do
      out = in_zone("UTC")

      expect(out.values_at("inThreeDays", "hoursAgo", "tomorrow")).to eq(["in 3 days", "2 hours ago", "tomorrow"])
    end
  end
end
