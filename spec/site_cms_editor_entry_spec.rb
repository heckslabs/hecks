require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "hecks/tools"
require "hecks/tools/site_routes"

# What the Editor row and the words rows may say about uploads, the register of people, the Markdown
# modules and ranges, and what the schema carries for each. The neutral project in
# spec/fixtures/site/editor_entry has them all.
RSpec.describe "the editor's uploads, people, Markdown and ranges, as declared" do
  let(:project) { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/editor_entry") }
  let(:site) { "bluebook/orchard_site.bluebook" }

  def files_of(dir = project)
    all = Hecks::Tools::SiteRoutes.projection(dir, out: "/work/out", editor: "/work/editor")
    all.select { |path, _| path.start_with?("/work/editor/") }.transform_keys { |path| path.delete_prefix("/work/editor/") }
  end

  def schema = JSON.parse(files_of.fetch("src/schema.ts")[/SCHEMA: Schema = (\{.*\});\n/m, 1])

  def tree = schema["aggregates"].find { |agg| agg["name"] == "Tree" }

  def attribute(name) = tree["attributes"].find { |attr| attr["name"] == name }

  # The projection's message when the row's file has `from` replaced by `to`, or "accepted".
  def refused(file, from, to)
    Dir.mktmpdir("cms_editor_entry") do |dir|
      FileUtils.cp_r(File.join(project, "."), dir)
      path = File.join(dir, file)
      raise "#{file} has no #{from.inspect}" unless File.read(path).include?(from)

      File.write(path, File.read(path).sub(from, to))
      files_of(dir)
      "accepted"
    rescue SystemExit => e
      e.message
    end
  end

  describe "the schema" do
    it "marks a field that holds a picture's or leaflet's address with where it is kept", :aggregate_failures do
      expect(attribute("picture")["upload"]).to eq("collection" => "media", "accept" => "image")
      expect(attribute("leaflet")["upload"]).to eq("collection" => "documents", "accept" => "pdf")
    end

    it "marks the end of each pair named starts_*/ends_*, at the top of a command and in a list's rows", :aggregate_failures do
      expect(attribute("ends_on")["after"]).to eq("starts_on")
      row_end = tree["valueObjects"]["Picking"].find { |part| part["name"] == "ends_on" }
      expect(row_end["after"]).to eq("starts_on")
    end

    it "marks a text a row calls Markdown, as the Markdown field the toolbar is for" do
      note = schema["aggregates"].find { |agg| agg["name"] == "Note" }
      expect(note["valueObjects"]["NoteText"].first["markdown"]).to be(true)
    end
  end

  describe "the Editor row" do
    it "needs the environment variable that names the content system when it names where files go" do
      expect(refused(site, %(upload_env: "ORCHARD_CMS_URL", ), "")).to include("upload_env must name the environment")
    end

    it "takes the register of people as Domain::Aggregate" do
      message = refused(site, %(members_aggregate: "Orchard::Member"), %(members_aggregate: "Member"))
      expect(message).to include("must be Domain::Aggregate")
    end

    it "takes the site's reader and renderer together, each with the name it exports", :aggregate_failures do
      expect(refused(site, %(markdown_render: "../site/show.mjs#toHtml"), %(markdown_render: ""))).to include("named together")
      bare = refused(site, %(markdown_parse: "../site/read.mjs#toNodes"), %(markdown_parse: "../site/read.mjs"))
      expect(bare).to include("the name it exports")
    end
  end

  describe "the words rows" do
    it "refuse a picture or file field that names no collection" do
      message = refused(site, %(attribute: "text", label: "Words", kind: "markdown"), %(attribute: "text", kind: "image"))
      expect(message).to include("needs picks")
    end
  end
end
