require "spec_helper"
require "json"
require_relative "support/editor_fixture_project"

# One editor over several bluebooks, and what it derives from the bluebooks' own declarations: the
# relationship pickers, the moments, and the listing. The neutral project in
# spec/fixtures/site/editor_chapters has two bluebooks (writing and pictures) that share an
# aggregate name; the files that differ from the single-chapter editor's are held as goldens,
# rewritten with `GOLDEN=rewrite`.
RSpec.describe "the editor over several bluebooks" do
  let(:project) { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/editor_chapters") }

  include_context "with an editor fixture project"

  # The files whose text depends on the project; every other file is the same template.
  def golden_files = %w[package.json src/config.ts src/schema.ts src/app.ts]

  def aggregate(name, chapter, dir = project)
    schema(dir)["aggregates"].find { |agg| agg["name"] == name && agg["chapter"] == chapter }
  end

  def attribute(name, chapter, attr, dir = project)
    aggregate(name, chapter, dir)["attributes"].find { |candidate| candidate["name"] == attr }
  end

  # The project with its Editor row changed, for the refusals.
  def with_row(from, to)
    Dir.mktmpdir("cms_editor_chapters") do |dir|
      FileUtils.cp_r(File.join(project, "."), dir)
      file = File.join(dir, "bluebook/press_site.bluebook")
      File.write(file, File.read(file).sub(from, to))
      yield dir
    end
  end

  describe "the projection" do
    it_behaves_like "an editor projection with committed goldens"
  end

  describe "the bluebooks" do
    it "names each aggregate's bluebook, in the order the row gives them", :aggregate_failures do
      data = schema

      expect(data["chapters"]).to eq(%w[Press Library])
      expect(data["aggregates"].map { |agg| "#{agg["chapter"]}.#{agg["name"]}" })
        .to eq(%w[Press.Article Press.Category Press.Note Library.MediaItem Library.Category Library.Gallery])
    end

    it "keeps two aggregates of one name apart, each with its own queries", :aggregate_failures do
      expect(aggregate("Category", "Press")["queries"].map { |query| query["name"] }).to eq(["Active"])
      expect(aggregate("Category", "Library")["queries"].map { |query| query["name"] }).to eq(["All"])
    end

    it "limits a bluebook to the roles the row names, and leaves another open", :aggregate_failures do
      expect(aggregate("Gallery", "Library")["roles"]).to eq(["Admin"])
      expect(aggregate("Article", "Press")).not_to have_key("roles")
    end

    it "finds the picture aggregate in the second bluebook and says which bluebook holds it" do
      expect(schema["media"]).to include("aggregate" => "MediaItem", "domain" => "Library", "listing" => "Pictures")
    end

    it "leaves out an aggregate named with its bluebook, and only that chapter's" do
      with_row('title: "Press editor"', 'title: "Press editor", skip: "Library::Category"') do |dir|
        expect(schema(dir)["aggregates"].map { |agg| "#{agg["chapter"]}.#{agg["name"]}" }).not_to include("Library.Category")
      end
    end

    it "is the single-chapter editor's schema, unchanged, for an editor of one bluebook", :aggregate_failures do
      other = File.join(InMemoryDomain::ROOT, "spec/fixtures/site/editor")
      text = Hecks::Tools::SiteRoutes.projection(other, out: "/w", editor: "/w/e").fetch("/w/e/src/schema.ts")
      single = JSON.parse(text[/SCHEMA: Schema = (\{.*\});\n/m, 1])

      expect(single).not_to have_key("chapters")
      expect(single["aggregates"].flat_map(&:keys)).not_to include("chapter", "roles")
    end
  end

  describe "the relationships it finds" do
    it "offers the same chapter's category for a list of category slugs, by what the declarations say", :aggregate_failures do
      picker = attribute("Article", "Press", "categories")["picker"]

      expect(picker).to include("target" => "Category", "chapter" => "Press", "key" => "slug", "label" => "name")
      expect(picker).to include("listing" => "Active", "strict" => true)
    end

    it "suggests pictures, without insisting, for a name ending in a picture word and Ref", :aggregate_failures do
      picker = attribute("Article", "Press", "cover")["picker"]

      expect(picker).to include("target" => "MediaItem", "chapter" => "Library", "listing" => "Pictures", "strict" => false)
    end

    it "reads a `<kind>:<slug>` key from the pattern of its attribute, and the aggregate each kind names", :aggregate_failures do
      kinds = attribute("Gallery", "Library", "key")["picker"]["kinds"]

      expect(kinds.map { |kind| kind["kind"] }).to eq(%w[article note])
      expect(kinds.map do |kind|
        [kind["target"], kind["chapter"], kind["label"]]
      end).to eq([%w[Article Press title], %w[Note Press key]])
    end

    it "gives no picker to an attribute that only looks like a key", :aggregate_failures do
      expect(attribute("Article", "Press", "title")).not_to have_key("picker")
      expect(attribute("Gallery", "Library", "name")).not_to have_key("picker")
    end

    it "offers a picture's key for a gallery's list of pictures" do
      expect(attribute("Gallery", "Library", "pictures")["picker"]).to include("target" => "MediaItem", "strict" => false)
    end
  end

  describe "the moments it finds" do
    it "reads a date from a value object named for one, and a date and time from an integer named for one", :aggregate_failures do
      expect(attribute("Article", "Press", "published_on")["widget"]).to eq("date")
      expect(attribute("Note", "Press", "remind_at")["widget"]).to eq("datetime")
    end

    it "leaves an ordinary integer alone", :aggregate_failures do
      expect(Hecks::Projections::Site::CmsEditor::Moment.widget(%w[duration])).to be_nil
      expect(Hecks::Projections::Site::CmsEditor::Moment.widget(%w[Season format Combat])).to be_nil
    end

    it "reads `_at`, `At`, `_on`, `On` and epoch as the names of a moment", :aggregate_failures do
      moment = Hecks::Projections::Site::CmsEditor::Moment

      expect(%w[created_at CreatedAt].map { |name| moment.widget([name]) }).to eq(%w[datetime datetime])
      expect(%w[due_on DueOn].map { |name| moment.widget([name]) }).to eq(%w[date date])
      expect(moment.widget(%w[epoch_seconds])).to eq("datetime")
    end
  end

  describe "the key convention" do
    def kinds(pattern) = Hecks::Projections::Site::CmsEditor::KeyKinds.of(pattern)

    it "reads one kind or a group of kinds ahead of the colon", :aggregate_failures do
      expect(kinds("^post:[a-z]+$")).to eq(["post"])
      expect(kinds("^(?:post|page|media_item):.+")).to eq(%w[post page media_item])
    end

    it "reads nothing from a pattern that does not start with kinds and a colon", :aggregate_failures do
      expect(kinds("^[a-z]+$")).to be_empty
      expect(kinds("^(Post|page):x")).to eq(["page"])
      expect(kinds(nil)).to be_empty
    end
  end

  describe "the Editor row" do
    it "is refused for a bluebook named twice" do
      with_row('chapter: "Press, Library"', 'chapter: "Press, Press"') do |dir|
        expect { files_of(dir) }.to raise_error(SystemExit, /chapter names "Press" twice/)
      end
    end

    it "is refused when chapter_roles names a bluebook the editor does not edit" do
      with_row('chapter_roles: "Library=Admin"', 'chapter_roles: "Nowhere=Admin"') do |dir|
        expect { files_of(dir) }.to raise_error(SystemExit, /not a bluebook of this editor/)
      end
    end

    it "is refused when page_size is not a whole number from 1 to 1000" do
      with_row('page_size: "2"', 'page_size: "0"') do |dir|
        expect { files_of(dir) }.to raise_error(SystemExit, /page_size "0" must be a whole number/)
      end
    end

    it "is refused when media names one of the bluebooks it edits" do
      with_row('title: "Press editor"', 'title: "Press editor", media: "Library"') do |dir|
        expect { files_of(dir) }.to raise_error(SystemExit, /is this editor's own bluebook/)
      end
    end
  end
end
