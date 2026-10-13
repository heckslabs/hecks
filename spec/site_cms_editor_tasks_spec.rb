require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "hecks/tools"
require "hecks/tools/site_routes"

# What the editor derives for a person who is not a developer, from one chapter's declarations and
# the route chapter's `EditorThing`, `EditorField` and `EditorCompanion` rows: the words of a task,
# the key a value object spells for another aggregate, a closed set written as one invariant, a long
# text bounded by an invariant, a moment held as text in a fixed zone, an aggregate that holds one
# record, and a note that belongs to a record. The neutral project in
# spec/fixtures/site/editor_tasks holds the files that depend on the project as goldens,
# rewritten with `GOLDEN=rewrite`.
RSpec.describe "the editor's task words, derived from a chapter and the route chapter's rows" do
  let(:project) { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/editor_tasks") }
  let(:golden)  { File.join(project, "expected/editor") }

  def golden_files = %w[package.json src/config.ts src/schema.ts src/app.ts src/ui/pages.ts src/ui/fields.ts]

  def files_of(dir = project)
    all = Hecks::Tools::SiteRoutes.projection(dir, out: "/work/out", editor: "/work/editor")
    all.select { |path, _| path.start_with?("/work/editor/") }.transform_keys { |path| path.delete_prefix("/work/editor/") }
  end

  def neutral(text) = text.gsub("^#{Hecks::VERSION}", "^<version>")

  def schema(dir = project) = JSON.parse(files_of(dir).fetch("src/schema.ts")[/SCHEMA: Schema = (\{.*\});\n/m, 1])

  def aggregate(name, dir = project) = schema(dir)["aggregates"].find { |agg| agg["name"] == name }

  def attribute(agg, name, dir = project) = aggregate(agg, dir)["attributes"].find { |attr| attr["name"] == name }

  def part(agg, object, name) = aggregate(agg)["valueObjects"].fetch(object).find { |one| one["name"] == name }

  # The project with some text of one of its files changed, by pairs of `from` and `to`.
  def changed(file, *edits)
    Dir.mktmpdir("cms_editor_tasks") do |dir|
      FileUtils.cp_r(File.join(project, "."), dir)
      path = File.join(dir, file)
      edits.each_slice(2) do |from, to|
        raise "#{file} has no #{from.inspect}" unless File.read(path).include?(from)

        File.write(path, File.read(path).gsub(from, to))
      end
      yield dir
    end
  end

  # What the projection says when `file` is changed by the pairs of text given, which it refuses.
  def refused(file, *edits)
    changed(file, *edits) do |dir|
      files_of(dir)
      "accepted"
    rescue SystemExit => e
      e.message
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

  describe "what the route chapter's rows say" do
    it "gives an aggregate its name, plural and the sentence about it", :aggregate_failures do
      plant = aggregate("Plant")

      expect(plant["words"]).to include("name" => "plant", "plural" => "plants", "about" => "The plants the garden grows.")
      expect(aggregate("Note")["words"]["advanced"]).to be(true)
    end

    it "gives an attribute its label, its help and where it is kept", :aggregate_failures do
      slug = attribute("Plant", "slug")

      expect(slug).to include("label" => "Address", "advanced" => true, "fill" => "slug_of:name")
      expect(attribute("Plant", "bed_slug")["label"]).to eq("Bed")
    end

    it "names a command's button and the same on the command's own form", :aggregate_failures do
      sow = aggregate("Plant")["commands"].find { |command| command["name"] == "Sow" }

      expect(sow["label"]).to eq("Save the plant")
      expect(sow["attributes"].find { |attr| attr["name"] == "slug" }).to include("advanced" => true)
    end

    it "marks a textarea, and a moment held as text with its zone, on the part a form is read against", :aggregate_failures do
      visits = part("Plant", "Visit", "note")

      expect(visits["multiline"]).to be(true)
      expect(part("Plant", "Visit", "at")["wall"]).to eq("-07:00")
      expect(part("Plant", "SownOn", "value")["wall"]).to eq("-07:00")
    end

    it "refuses a row that names something the chapters do not have, naming every row at once", :aggregate_failures do
      message = refused("bluebook/garden_site.bluebook",
                        'attribute: "bed_slug", label: "Bed"', 'attribute: "bed_slugg", label: "Bed"',
                        'aggregate: "Almanac", name: "almanac"', 'aggregate: "Almanacs", name: "almanac"')

      expect(message).to include("bed_slugg", "Almanacs")
    end

    it "refuses a zone with no moment, and a fill it does not know", :aggregate_failures do
      message = refused("bluebook/garden_site.bluebook", 'fill: "slug_of:name"', 'fill: "someday"',
                        'kind: "textarea", help: "Plain sentences."', 'zone: "-07:00", help: "Plain sentences."')

      expect(message).to include("zone needs kind datetime", "fill \"someday\"")
    end
  end

  describe "what the chapter's own declarations say" do
    it "offers another aggregate's records where a value object is spelled as its identity", :aggregate_failures do
      picker = attribute("Plant", "bed_slug")["picker"]

      expect(picker).to include("target" => "Bed", "key" => "slug", "label" => "title", "listing" => "Listing", "strict" => true)
    end

    it "never makes an aggregate's own identity a reference to itself", :aggregate_failures do
      expect(attribute("Bed", "slug")).not_to have_key("picker")
      expect(aggregate("Bed")["commands"].first["attributes"].first).not_to have_key("picker")
    end

    it "offers the records a row names, when the model's names say nothing" do
      expect(attribute("Plant", "mentor")["picker"]).to include("target" => "Gardener", "label" => "name")
    end

    it "reads a closed set written as one invariant as a choice", :aggregate_failures do
      expect(attribute("Plant", "kind")["options"]).to eq(%w[herb shrub tree])
    end

    it "writes a long text in a box when an invariant bounds it above 200 characters", :aggregate_failures do
      expect(part("Plant", "Description", "value")).to include("maxLength" => 600, "multiline" => true)
    end

    it "says an aggregate whose identity is one literal holds one record, keyed by it" do
      expect(aggregate("Almanac")["single"]).to eq("almanac")
    end

    it "carries a picture slot's key prefix when its pattern asks for one" do
      expect(attribute("Plant", "figure")["picture"]).to include("key" => "media_ref", "alt" => "alt", "prefix" => "media:")
    end
  end

  describe "where a record is shown on the site" do
    it "is a template of the aggregate's own, and the row's choice of a tab or a drawer", :aggregate_failures do
      config = files_of.fetch("src/config.ts")

      expect(aggregate("Plant")["words"]["preview"]).to eq("/plants/{slug}")
      expect(config).to include('previewIn: "tab"')
    end

    it "is refused when the previews would be framed from more than one origin" do
      message = refused("bluebook/garden_site.bluebook", 'preview_in: "tab"', 'preview_in: "drawer"',
                        'preview: "/plants/{slug}"', 'preview: "https://example.org/{slug}"',
                        'member aggregate: "Almanac", name: "almanac", plural: "almanac"',
                        'member aggregate: "Almanac", name: "almanac", plural: "almanac", preview: "/almanac"')

      expect(message).to include("more than one origin")
    end
  end

  describe "a note that belongs to a record" do
    it "is a related panel of the plant, keyed from the plant's own, the first that holds being shown", :aggregate_failures do
      related = aggregate("Plant")["related"]
      made = { "shape" => "text", "attribute" => "text", "when" => "kind is tree", "create" => "Write", "edit" => "Rewrite" }

      expect(related.map { |one| one["key"] }).to eq(["tree.{slug}.note", "plant.{slug}.note"])
      expect(related.first).to include(made)
    end
  end
end
