require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "hecks/tools"
require "hecks/tools/site_routes"

# What the editor derives, from one chapter's declarations, for editing a page of a fixed structure:
# a working copy that is a value object (or a list) and not a body, a picture slot outside a block
# list, a writing box for a text a rule lets run long, and the limits a holder's invariants give a
# repeated group. Each rule reads shape, never a name, so the examples change the declarations and
# look at what is derived. The neutral project in spec/fixtures/site/editor_fixed_pages holds the
# files that depend on the project as goldens, rewritten with `GOLDEN=rewrite`.
RSpec.describe "the editor's fixed-structure pages, derived from a chapter" do
  let(:project) { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/editor_fixed_pages") }
  let(:golden)  { File.join(project, "expected/editor") }
  let(:leaflets) { "domain/bluebook/leaflets.bluebook" }

  def golden_files = %w[package.json src/config.ts src/schema.ts src/app.ts]

  def files_of(dir = project)
    all = Hecks::Tools::SiteRoutes.projection(dir, out: "/work/out", editor: "/work/editor")
    all.select { |path, _| path.start_with?("/work/editor/") }.transform_keys { |path| path.delete_prefix("/work/editor/") }
  end

  def neutral(text) = text.gsub("^#{Hecks::VERSION}", "^<version>")

  def schema(dir = project) = JSON.parse(files_of(dir).fetch("src/schema.ts")[/SCHEMA: Schema = (\{.*\});\n/m, 1])

  def aggregate(name, dir = project) = schema(dir)["aggregates"].find { |agg| agg["name"] == name }

  def part(aggregate_name, object, name, dir = project)
    aggregate(aggregate_name, dir)["valueObjects"].fetch(object).find { |one| one["name"] == name }
  end

  # The project with some text of one of its files changed (`from`, `to`, and more pairs of the same).
  def changed(file, *edits)
    Dir.mktmpdir("cms_editor_fixed_pages") do |dir|
      FileUtils.cp_r(File.join(project, "."), dir)
      path = File.join(dir, file)
      edits.each_slice(2) do |from, to|
        raise "#{file} has no #{from.inspect}" unless File.read(path).include?(from)

        File.write(path, File.read(path).gsub(from, to))
      end
      yield dir
    end
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

  describe "the working copy of a page" do
    it "finds a value object as the draft a command saves, publishes and discards" do
      expect(aggregate("ChaptersPage")["drafts"]).to eq(
        "attribute" => "draft_content", "live" => "content", "save" => "SaveDraft",
        "publish" => "PublishDraft", "discard" => "DiscardDraft"
      )
    end

    it "finds a list of value objects as the draft, and sends the clearing argument as an empty list", :aggregate_failures do
      roster = aggregate("RosterPage")
      publish = roster["commands"].find { |command| command["name"] == "PublishDraft" }

      expect(roster["drafts"]).to include("attribute" => "draft_people", "live" => "people")
      expect(publish).to include("attributes" => [], "empty" => ["nothing"])
    end

    it "leaves the clearing argument of a value object out of the form and sends nothing for it" do
      publish = aggregate("ChaptersPage")["commands"].find { |command| command["name"] == "PublishDraft" }

      expect(publish).to include("attributes" => []).and(satisfy { |command| !command.key?("empty") })
    end

    it "finds no working copy when the draft is not of the type of the live content", :aggregate_failures do
      changed(leaflets, "attribute :draft_content, NoteContent, optional: true",
              "attribute :draft_content, LeafletKey, optional: true",
              "attribute :draft_content, NoteContent\n", "attribute :draft_content, LeafletKey\n") do |dir|
        expect(aggregate("NotePage", dir)).not_to have_key("drafts")
      end
    end
  end

  describe "the limits a holder's rules give a repeated group" do
    it "reads the fewest and the most rows of a list from the value object's invariants" do
      expect(part("ChaptersPage", "ChaptersContent", "chapters")).to include("min" => 1, "max" => 60)
    end

    it "reads the limit of a group nested in a group" do
      expect(part("ChaptersPage", "Chapter", "parts")).to include("max" => 12).and(satisfy { |one| !one.key?("min") })
    end

    it "reads a limit from a command's given when the list is the aggregate's own" do
      roster = aggregate("RosterPage")["commands"].find { |command| command["name"] == "SaveDraft" }

      expect(roster["attributes"].first).to include("name" => "draft_people", "max" => 60)
    end

    it "takes the tighter of two rules about one list" do
      changed(leaflets, "invariant(\"a page has at most 60 chapters\") { chapters.size <= 60 }",
              "invariant(\"a page has at most 60 chapters\") { chapters.size <= 60 }\n      " \
              "invariant(\"a page has at most 20 chapters\") { chapters.size <= 20 }") do |dir|
        expect(part("ChaptersPage", "ChaptersContent", "chapters", dir)).to include("max" => 20)
      end
    end

    it "gives no limit to a list no rule bounds" do
      changed(leaflets, "invariant(\"a chapter has at most 12 parts\") { parts.size <= 12 }", "") do |dir|
        expect(part("ChaptersPage", "Chapter", "parts", dir)).not_to have_key("max")
      end
    end
  end

  describe "a text a rule lets run long" do
    it "is a writing box when a rule bounds it above 200 characters", :aggregate_failures do
      summary = part("NotePage", "NoteContent", "summary")

      expect(summary).to include("maxLength" => 600, "multiline" => true)
      expect(part("RosterPage", "Person", "about")).to include("maxLength" => 1000, "multiline" => true)
    end

    it "keeps a text a rule bounds at 200 or fewer a single line, and still carries the bound", :aggregate_failures do
      heading = part("NotePage", "NoteContent", "heading")

      expect(heading).to include("maxLength" => 120)
      expect(heading).not_to have_key("multiline")
    end

    it "leaves a text no rule bounds as it is", :aggregate_failures do
      more = part("NotePage", "NoteContent", "more")

      expect(more).not_to have_key("maxLength")
      expect(more).not_to have_key("multiline")
    end

    it "reads a bound written after a guard on the same part" do
      changed(leaflets, "invariant(\"a heading is at most 120 characters\") { heading.to_s.size <= 120 }",
              "invariant(\"a heading is at most 300 characters\") { heading.unset? || heading.size <= 300 }") do |dir|
        expect(part("NotePage", "NoteContent", "heading", dir)).to include("maxLength" => 300, "multiline" => true)
      end
    end

    it "does not read a bound that guards a different part" do
      changed(leaflets, "invariant(\"a heading is at most 120 characters\") { heading.to_s.size <= 120 }",
              "invariant(\"a heading is at most 300 characters\") { more.unset? || heading.size <= 300 }") do |dir|
        expect(part("NotePage", "NoteContent", "heading", dir)).not_to have_key("maxLength")
      end
    end
  end

  describe "a picture slot" do
    def picture = { "key" => "media_ref", "alt" => "alt", "caption" => "caption" }

    it "is found in a value object, in a part of a group's member, and in a list of pictures", :aggregate_failures do
      expect(part("ChaptersPage", "Hero", "picture")).to include("picture" => picture)
      expect(part("ChaptersPage", "Chapter", "band")).to include("picture" => picture)
      expect(part("GalleryPage", "GalleryContent", "photos")).to include("picture" => picture)
    end

    it "is found whatever the value object is called, from the parts it has" do
      changed(leaflets, "value_object \"Band\"", "value_object \"Strip\"", "attribute :band,    Band, optional: true",
              "attribute :band,    Strip, optional: true") do |dir|
        expect(part("ChaptersPage", "Chapter", "band", dir)).to include("picture" => picture)
      end
    end

    it "is not found when the description is missing" do
      before = "      attribute :alt,       String\n      attribute :caption,   String, optional: true\n"
      after = "      attribute :caption,   String, optional: true\n"
      changed(leaflets, "#{before}      attribute :align,", "#{after}      attribute :align,") do |dir|
        expect(part("ChaptersPage", "Chapter", "band", dir)).not_to have_key("picture")
      end
    end

    it "is not found in the blocks of a body, which the rich-text widget edits", :aggregate_failures do
      blocks = part("NotePage", "Body", "blocks")

      expect(blocks).not_to have_key("picture")
      expect(part("NotePage", "NoteContent", "body")).to include("widget" => "body")
    end
  end

  describe "the generated files" do
    let(:files) { files_of }

    it "loads the page's script for the picker and the form as a whole from the list's script", :aggregate_failures do
      script = files.fetch("src/browser/blocks.js")

      expect(script).to include("form[data-draft-form]", "function enhanceLoose", "function guardPictures")
      expect(files.fetch("src/browser/main.js")).to include("enhanceBlocks();")
    end

    it "marks a form whose working copy is a value object as saved as a whole", :aggregate_failures do
      pages = files.fetch("src/ui/pages.ts")

      expect(pages).to include("data-draft-form")
      expect(pages).to include("startingValues")
    end

    it "mentions no name of this project in a template of fixed pages", :aggregate_failures do
      text = files.values_at("src/ui/fields.ts", "src/ui/blocks.ts", "src/ui/block_list.js", "src/ui/input.ts",
                             "src/ui/values.ts", "src/ui/pages.ts", "src/browser/blocks.js", "src/browser/forms.js").join
      names = [/\bLeaflets?\b/, /\b(Note|Chapters|Gallery|Roster)Page\b/, /\bhero\b/i, /\bverse\b/i, /\bband\b/i,
               /\bportrait\b/i, /\bphotos?\b/i]

      expect(names.map { |name| text.match?(name) }).to eq([false] * names.size)
    end
  end
end
