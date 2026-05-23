// AUTO-GENERATED — daily-musing bluebooks embedded into the Worker WASM.
// To regenerate (until `hecks-life compile` ships per inbox/i103) :
//   python3 worker/scripts/regenerate-embedded.py
//
// Embedded files : 3
// Primary        : daily_musing.bluebook

pub const PRIMARY_BASENAME: &str = "daily_musing.bluebook";
pub const BLUEBOOK_COUNT:   usize = 3;

pub static EMBEDDED_BLUEBOOKS: &[(&str, &str)] = &[
    ("daily_musing.bluebook", r#####"Hecks.bluebook "DailyMusing", version: "2026.05.23.2" do
  vision "An author posts blog entries to the Daily Musing so readers can read them."
  category "blog"

  aggregate "BlogEntry", "A single post in the Daily Musing — its title, body, author, and published state" do
    attribute :title, Title
    attribute :body, Body
    attribute :author, AuthorName
    attribute :published_at, PublishedAt

    value_object "Title" do
      attribute :value, String
    end
    value_object "Body" do
      attribute :value, String
    end
    value_object "AuthorName" do
      attribute :value, String
    end
    value_object "PublishedAt" do
      attribute :value, String
    end

    command "Post" do
      role "Author"
      description "Publish a blog entry to the Daily Musing so readers can read it"
      attribute :title, Title
      attribute :body, Body
      attribute :author, AuthorName
      attribute :published_at, PublishedAt
      then_set :title, to: :title
      then_set :body, to: :body
      then_set :author, to: :author
      then_set :published_at, to: :published_at
      emits "EntryPosted"
    end

    lifecycle :status, default: "draft" do
      transition "Post" => "published", from: "draft"
    end

    query "DailyMusing" do
      description "Readers' view — every published entry in the Daily Musing"
      where status: "published"
    end
  end
end
"#####),
    ("daily_musing.fixtures", r#####"Hecks.fixtures "DailyMusing" do
  # Seed musings so a fresh, memory-only Worker boot already has a
  # readable Daily Musing. Each Worker request boots a fresh in-memory
  # runtime ; without persistence (R2, a later phase) these seeds are
  # the published entries every GET returns. A live POST appears in
  # that request's cascade but does not survive into the next request
  # until R2 is wired.
  #
  # Form : nested `aggregate "BlogEntry" do fixture "Label", k: v ... end`
  # — the dialect storehouse::fixtures_parser parses (see its header).
  # The BlogEntry query `DailyMusing` filters `where status: "published"`,
  # so every seed sets status explicitly. Values are flat — the Worker's
  # seed_fixtures path sets them straight onto AggregateState, matching
  # the shape the query reads back.

  aggregate "BlogEntry" do
    fixture "EntryWelcome",
      title: "Welcome to the Daily Musing",
      body: "This blog runs on a single Hecks bluebook compiled to WebAssembly and served from a Cloudflare Worker — no container, no server. The domain IS the contract.",
      author: "Miette",
      published_at: "2026-05-23T08:00:00Z",
      status: "published"

    fixture "EntryMorningLight",
      title: "Morning Light",
      body: "A quiet musing on starting the day with a clear bluebook and a warm runtime.",
      author: "Chris",
      published_at: "2026-05-23T09:30:00Z",
      status: "published"
  end
end
"#####),
    ("daily_musing.hecksagon", r#####"Hecks.hecksagon "DailyMusing" do
  adapter :memory
end
"#####),
];
