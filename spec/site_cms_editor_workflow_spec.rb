require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "hecks/tools"
require "hecks/tools/site_routes"

# What the editor derives, from the declarations of five separate chapters, for working on a post as
# one thing: the records keyed by it, the scheduled actions for it, its preview, and the draft its
# text is written as. Each rule reads shape (a key's declared pattern, a closed set, a moment, a
# lifecycle, `draft_` attributes), never a name, so the examples change the declarations and the
# names and look at what is derived. The neutral project in spec/fixtures/site/editor_workflow holds
# the files that depend on the project as goldens, rewritten with `GOLDEN=rewrite`.
RSpec.describe "the editor's workflow, derived from the chapters" do
  let(:project) { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/editor_workflow") }
  let(:golden)  { File.join(project, "expected/editor") }

  def golden_files = %w[package.json src/config.ts src/schema.ts src/app.ts]

  def files_of(dir = project)
    all = Hecks::Tools::SiteRoutes.projection(dir, out: "/work/out", editor: "/work/editor")
    all.select { |path, _| path.start_with?("/work/editor/") }.transform_keys { |path| path.delete_prefix("/work/editor/") }
  end

  def neutral(text) = text.gsub("^#{Hecks::VERSION}", "^<version>")

  def schema(dir = project) = JSON.parse(files_of(dir).fetch("src/schema.ts")[/SCHEMA: Schema = (\{.*\});\n/m, 1])

  def aggregate(name, dir = project) = schema(dir)["aggregates"].find { |agg| agg["name"] == name }

  # The project with some text of one of its files changed (`from`, `to`, and more pairs of the
  # same), for what is derived from other words.
  def changed(file, *edits)
    Dir.mktmpdir("cms_editor_workflow") do |dir|
      FileUtils.cp_r(File.join(project, "."), dir)
      path = File.join(dir, file)
      edits.each_slice(2) do |from, to|
        raise "#{file} has no #{from.inspect}" unless File.read(path).include?(from)

        File.write(path, File.read(path).gsub(from, to))
      end
      yield dir
    end
  end

  def related_names(name, dir = project) = (aggregate(name, dir)["related"] || []).map { |rel| rel["aggregate"] }

  def preview_row(template, &)
    changed("bluebook/newsroom_site.bluebook", "https://site.example.com/{kind}/{slug}?preview=1", template, &)
  end

  describe "the projection" do
    it "equals the committed goldens for the files that depend on the project", :aggregate_failures do
      rewrite_goldens if ENV["GOLDEN"] == "rewrite"

      golden_files.each do |name|
        expect(neutral(files_of.fetch(name))).to eq(File.read(File.join(golden, name))), "#{name} has drifted from its golden"
      end
    end

    def rewrite_goldens
      FileUtils.rm_rf(golden)
      golden_files.each do |name|
        FileUtils.mkdir_p(File.dirname(File.join(golden, name)))
        File.write(File.join(golden, name), neutral(files_of.fetch(name)))
      end
    end
  end

  describe "what a first run against a real host and a phone found" do
    let(:files) { files_of }

    it "treats a query the host does not answer as a refusal, not an empty list", :aggregate_failures do
      expect(files.fetch("src/host.ts")).to include("export function rowsAnswered", "QueryNotAnswered")
      %w[src/app.ts src/choices.ts src/media/handler.ts].each do |name|
        expect(files.fetch(name)).to include("rowsAnswered"), name
        expect(files.fetch(name)).not_to include("rowsOf("), name
      end
    end

    it "makes the preview drawer a modal dialog with a button that closes it, and keeps focus in it", :aggregate_failures do
      expect(files.fetch("src/ui/preview.ts")).to include('aria-modal="true"', "data-preview-close")
      expect(files.fetch("src/ui/preview.ts")).not_to include('<label for="preview-toggle" class="btn')
      expect(files.fetch("src/browser/preview.js")).to include("focusInto(", 'event.key !== "Tab"')
    end

    it "offers views as links, not as an ARIA tab list it does not implement", :aggregate_failures do
      expect(files.fetch("src/ui/table.ts")).not_to include('role="tab"', 'role="tablist"')
    end

    it "gives a refusal the reason in its heading, not 'Not found'", :aggregate_failures do
      expect(files.fetch("src/app.ts")).to include('"The domain is not answering"', '"Not open to your role"')
      expect(files.fetch("src/ui/pages.ts")).to include('notFound(what: string, title = "Not found")')
    end

    it "sizes controls for a finger, lets the toolbar scroll, and lets a fieldset shrink", :aggregate_failures do
      css = files.fetch("src/browser/app.css")
      expect(css).to include("@media (pointer: coarse), (max-width: 40rem)", "min-height: 2.75rem", "min-inline-size: 0")
      expect(css).to include(".tab:not(.tab-active):not(:hover)")
      expect(files.fetch("src/browser/body_editor.js")).to include("overflow-x-auto", "sm:flex-wrap")
    end

    it "keeps the picture picker's panel inside the window, with its own scroll", :aggregate_failures do
      css = files.fetch("src/browser/app.css")
      picker = files.fetch("src/browser/media_picker.js")
      expect(css).to include(".picker-panel {", "max-height: calc(100dvh -", ".file-input {")
      expect(picker).to include("fixed inset-x-2", "overflow-y-auto", "visualViewport", "safe-area-inset-bottom")
      expect(picker).not_to include("absolute left-2")
    end

    it "stops the picture picker above the sticky action bar, which clears the home indicator", :aggregate_failures do
      expect(files.fetch("src/browser/media_picker.js")).to include("[data-actionbar]")
      expect(files.fetch("src/ui/pages.ts")).to include("data-actionbar", "env(safe-area-inset-bottom)")
    end
  end

  describe "the records that go with a record" do
    it "relates an aggregate to the aggregates whose identity is a key of its kind, by shape", :aggregate_failures do
      related = aggregate("Post")["related"]

      expect(related.map { |rel| rel.values_at("aggregate", "chapter", "shape") })
        .to eq([%w[Document Documents document], %w[Gallery Pictures gallery], %w[SearchWording Discovery metadata]])
      expect(related.map { |rel| rel.values_at("create", "edit") })
        .to eq([%w[Begin SaveDraft], %w[Gather Rearrange], %w[Describe Reword]])
    end

    it "relates a page by the same keys, since a key's kinds are `post|page`" do
      expect(related_names("Page")).to eq(%w[Document Gallery SearchWording])
    end

    it "relates nothing to an aggregate no key names, nor to the aggregates that hold the keys", :aggregate_failures do
      expect(aggregate("MediaItem")).not_to have_key("related")
      expect(aggregate("Document")).not_to have_key("related")
    end

    it "does not relate an aggregate whose key does not say it is one, whatever it is named", :aggregate_failures do
      changed("domain/bluebook/pictures.bluebook", "attribute :value, String, pattern: '^(post|page):[a-z0-9-]+$'",
              "attribute :value, String") do |dir|
        expect(related_names("Post", dir)).to eq(%w[Document SearchWording])
      end
    end

    it "relates it by the kind alone: renamed, an aggregate is related all the same", :aggregate_failures do
      changed("domain/bluebook/discovery.bluebook", "SearchWording", "SeoRecord") do |dir|
        expect(related_names("Post", dir)).to eq(%w[Document Gallery SeoRecord])
        expect(aggregate("Post", dir)["related"].last).to include("shape" => "metadata", "create" => "Describe")
      end
    end

    it "does not relate an aggregate for a kind that no aggregate is named", :aggregate_failures do
      changed("domain/bluebook/discovery.bluebook", "(post|page)", "(article|page)") do |dir|
        expect(related_names("Post", dir)).to eq(%w[Document Gallery])
        expect(related_names("Page", dir)).to eq(%w[Document Gallery SearchWording])
      end
    end

    it "edits a document by its draft-saving command, and a gallery by the command that takes its pictures",
       :aggregate_failures do
      editing = aggregate("Post")["related"].to_h { |rel| [rel["aggregate"], rel["edit"]] }

      expect(editing).to include("Document" => "SaveDraft", "Gallery" => "Rearrange")
    end
  end

  describe "the scheduled actions" do
    it "finds the aggregate by the shape of its subject, action, due time, lifecycle and commands", :aggregate_failures do
      expect(schema["scheduling"]).to eq(
        "aggregate" => "ScheduledAction", "chapter" => "Schedule", "subject" => "subject", "action" => "action",
        "actions" => %w[publish withdraw], "due" => "due_at", "pending" => "pending", "schedule" => "Schedule",
        "reschedule" => "Reschedule", "cancel" => "Cancel", "query" => "ForSubject", "reason" => "reason", "generated" => true
      )
    end

    it "finds it under another name, since nothing in it is a name", :aggregate_failures do
      changed("domain/bluebook/schedule.bluebook", "ScheduledAction", "Chore") do |dir|
        expect(schema(dir)["scheduling"]).to include("aggregate" => "Chore", "schedule" => "Schedule")
      end
    end

    it "finds none without a closed set of actions" do
      changed("domain/bluebook/schedule.bluebook", ', one_of: ["publish", "withdraw"]', "") do |dir|
        expect(schema(dir)).not_to have_key("scheduling")
      end
    end

    it "finds none when the subject is not declared a key of a kind" do
      changed("domain/bluebook/schedule.bluebook", "attribute :value, String, pattern: '^(post|page):[a-z0-9-]+$'",
              "attribute :value, String") do |dir|
        expect(schema(dir)).not_to have_key("scheduling")
      end
    end

    it "finds none without a due time that is a moment" do
      changed("domain/bluebook/schedule.bluebook", "due_at", "after", "DueAt", "Instant") do |dir|
        expect(schema(dir)).not_to have_key("scheduling")
      end
    end

    it "finds none when the first state does not lead to two final states" do
      changed("domain/bluebook/schedule.bluebook", %(      transition "Fail" => "failed", from: "pending"\n), "",
              %(      transition "Complete" => "done", from: "pending"\n), "") do |dir|
        expect(schema(dir)).not_to have_key("scheduling")
      end
    end

    it "finds the query by its one argument, the subject, whatever it is called", :aggregate_failures do
      changed("domain/bluebook/schedule.bluebook", "ForSubject", "Everything") do |dir|
        expect(schema(dir)["scheduling"]).to include("query" => "Everything", "cancel" => "Cancel")
      end
    end

    it "leaves out the query that takes more than the subject, and the commands it does not find", :aggregate_failures do
      two_arguments = ["attribute :subject, SubjectKey\n      where",
                       "attribute :subject, SubjectKey\n      attribute :action, ActionName\n      where"]
      changed("domain/bluebook/schedule.bluebook", *two_arguments, "Cancel", "Stop") do |dir|
        expect(schema(dir)["scheduling"]).to include("cancel" => "Stop").and(satisfy { |found| !found.key?("query") })
      end
    end

    it "makes the identity itself only when the subject is not the identity", :aggregate_failures do
      expect(schema["scheduling"]).to include("generated" => true)
      expect(schema["scheduling"]["subject"]).not_to eq(aggregate("ScheduledAction")["identity"])
    end
  end

  describe "a closed set" do
    it "is offered as the members it names, on the attribute whose value object declares them", :aggregate_failures do
      action = aggregate("ScheduledAction")["attributes"].find { |attr| attr["name"] == "action" }

      expect(action["options"]).to eq(%w[publish withdraw])
      expect(aggregate("Post")["attributes"].map { |attr| attr["options"] }.compact).to be_empty
    end
  end

  describe "the drafts" do
    it "finds the draft-saving, publishing and discarding commands by the shape of the draft attribute", :aggregate_failures do
      expect(aggregate("Document")["drafts"]).to eq(
        "attribute" => "draft_body", "live" => "body", "save" => "SaveDraft",
        "publish" => "PublishDraft", "discard" => "DiscardDraft"
      )
      expect(aggregate("Post")).not_to have_key("drafts")
    end

    it "finds no drafts when the command's argument is not a `draft_` counterpart of an attribute held", :aggregate_failures do
      changed("domain/bluebook/documents.bluebook", "attribute :draft_body, Body\n\n      sets :draft_body\n",
              "attribute :wording, Body\n\n      sets :draft_body, to: :wording\n") do |dir|
        expect(aggregate("Document", dir)).not_to have_key("drafts")
      end
    end

    it "leaves out the commands it does not find", :aggregate_failures do
      changed("domain/bluebook/documents.bluebook", "DiscardDraft", "Throw") do |dir|
        expect(aggregate("Document",
                         dir)["drafts"]).to include("save" => "SaveDraft", "publish" => "PublishDraft", "discard" => "Throw")
      end
    end
  end

  describe "the preview" do
    it "holds the template, and names its origin as the only frame source", :aggregate_failures do
      template = "https://site.example.com/{kind}/{slug}?preview=1"
      expect(files_of.fetch("src/config.ts")).to include(%(preview: "#{template}" as string | null))
      expect(files_of.fetch("src/app.ts")).to include('  "frame-src https://site.example.com",')
    end

    it "takes a path on the editor's own origin, framed from `'self'`", :aggregate_failures do
      preview_row("/preview/{key}") do |dir|
        expect(files_of(dir).fetch("src/app.ts")).to include(%(  "frame-src 'self'",))
        expect(files_of(dir).fetch("src/config.ts")).to include('preview: "/preview/{key}"')
      end
    end

    it "names no frame source and no preview when the row has none", :aggregate_failures do
      other = File.join(InMemoryDomain::ROOT, "spec/fixtures/site/editor")
      text = Hecks::Tools::SiteRoutes.projection(other, out: "/w", editor: "/w/e")

      expect(text.fetch("/w/e/src/app.ts")).not_to include("frame-src")
      expect(text.fetch("/w/e/src/config.ts")).to include("preview: null as string | null")
    end

    [
      ["javascript:alert(1)", /must be an http\(s\) address or a path/],
      ["ftp://files.example.com/{slug}", /must be an http\(s\) address or a path/],
      ["//evil.example.com/{slug}", /must not start with two slashes/],
      ["https://user:secret@site.example.com/{slug}", /must not name credentials/],
      ["https://{kind}.example.com/{slug}", /must not hold a placeholder in the scheme, host or port/],
      ["https://site.example.com/{title}", /names the placeholder \{title\}/],
      ["https://site.example.com/{slug", /has a brace that is not part of a placeholder/],
      ["https://site.example.com/a b", /must not hold whitespace/]
    ].each do |template, problem|
      it "refuses #{template.inspect}" do
        preview_row(template) { |dir| expect { files_of(dir) }.to raise_error(SystemExit, problem) }
      end
    end
  end

  describe "the Editor row" do
    it "refuses a chapter named for the screen of scheduled actions" do
      changed("bluebook/newsroom_site.bluebook", "Documents, Pictures", "scheduled, Pictures") do |dir|
        expect { files_of(dir) }.to raise_error(SystemExit, /chapter "scheduled" is the first part of an address/)
      end
    end
  end
end
