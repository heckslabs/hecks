require "spec_helper"
require "json"
require_relative "support/editor_fixture_project"

# What the editor derives, from one chapter's declarations, for editing an ordered list of mixed
# blocks: a `list_of` value object that has a discriminator (a part that is one of a closed set).
# Each rule reads shape, never a name, so the examples change the declarations and look at what is
# derived. The neutral project in spec/fixtures/site/editor_sections holds the files that depend on
# the project, and the three files only a block list needs, as goldens, rewritten with
# `GOLDEN=rewrite`.
RSpec.describe "the editor's block lists, derived from a chapter" do
  let(:project) { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/editor_sections") }
  let(:layouts) { "domain/bluebook/layouts.bluebook" }

  include_context "with an editor fixture project"

  def golden_files
    %w[package.json src/config.ts src/schema.ts src/app.ts src/ui/blocks.ts src/ui/block_list.js src/browser/blocks.js]
  end

  def layout(dir = project) = schema(dir)["aggregates"].find { |agg| agg["name"] == "PageLayout" }

  def block_list(name = "panels", dir = project) = layout(dir)["attributes"].find { |attr| attr["name"] == name }["blockList"]

  describe "the projection" do
    it_behaves_like "an editor projection with committed goldens"
  end

  describe "finding a block list" do
    it "reads the kinds from the closed set the discriminator is" do
      expect(block_list).to include("discriminator" => "kind",
                                    "kinds"         => %w[hero text image columns cards quote
                                                          call_to_action gallery faq profile])
    end

    it "finds the working copy as a block list of the same shape" do
      expect(block_list("draft_panels")).to eq(block_list)
    end

    it "reads the limits of the list parts from the invariants, and of the list from a command's given", :aggregate_failures do
      expect(block_list.fetch("limits")).to eq("links" => 8, "entries" => 60)
      expect(layout["attributes"].find { |attr| attr["name"] == "panels" }["max"]).to eq(100)
    end

    it "finds the parts that make a picture, for the block and for the entries it holds" do
      expect(block_list.fetch("pictures")).to eq(
        "Panel" => { "key" => "media_ref", "alt" => "alt",
"caption" => "caption" }, "Entry" => { "key" => "media_ref", "alt" => "alt" }
      )
    end

    it "finds a text part that an invariant restricts to a list of kinds when the kind is no closed set" do
      rule = "invariant(\"a panel is a known kind\") { [\"hero\", \"text\"].include?(kind) }"
      changed(layouts, "attribute :kind,          PanelKind", "attribute :kind,          String\n      #{rule}") do |dir|
        expect(block_list("panels", dir)["kinds"]).to eq(%w[hero text])
      end
    end

    it "does not take a list of one kind of thing for a block list", :aggregate_failures do
      names = layout["valueObjects"]["Panel"].select { |part| part["list"] }.map { |part| [part["name"], part.key?("blockList")] }

      expect(names).to eq([["links", false], ["entries", false]])
    end

    it "does not take a body's blocks for a block list, which the rich-text widget edits" do
      body = layout["valueObjects"]["Panel"].find { |part| part["name"] == "body" }

      expect(body).to include("widget" => "body")
    end
  end

  describe "which slots each kind uses" do
    it "reads them from the declared table of rows: what a kind requires and what it may use", :aggregate_failures do
      expect(block_list.dig("rules", "hero")).to eq("requires" => %w[heading], "uses" => %w[subheading summary media_ref links])
      expect(block_list.dig("rules", "call_to_action", "requires")).to eq(%w[heading links])
    end

    it "gives no rules and says which parts a kind's invariants read when there is no table", :aggregate_failures do
      changed(layouts, "requires", "needs") do |dir|
        found = block_list("panels", dir)

        expect(found).not_to have_key("rules")
        expect(found.dig("mentions", "hero")).to eq(%w[heading])
      end
    end

    it "ignores a table whose rows name a kind the list does not have" do
      changed(layouts, 'member kind: "profile",', 'member kind: "poem",') do |dir|
        expect(block_list("panels", dir)).not_to have_key("rules")
      end
    end
  end

  describe "drafts" do
    it "finds a block list as the draft a command saves, publishes and discards" do
      expect(layout["drafts"]).to eq(
        "attribute" => "draft_panels", "live" => "panels", "save" => "SaveDraft",
        "publish" => "PublishDraft", "discard" => "DiscardDraft"
      )
    end

    it "leaves the clearing argument out of the form and sends it empty" do
      publish = layout["commands"].find { |command| command["name"] == "PublishDraft" }

      expect(publish).to include("empty" => ["nothing"], "attributes" => [])
    end
  end

  describe "the generated files" do
    it "writes the block list's three files" do
      expect(files_of.keys).to include("src/ui/blocks.ts", "src/ui/block_list.js", "src/browser/blocks.js")
    end

    it "loads the block list's script from the page's own script" do
      expect(files_of.fetch("src/browser/main.js")).to include('import { enhanceBlocks } from "./blocks.js";', "enhanceBlocks();")
    end

    it "names the picture picker's loader in the block list's script, which is null when there are no pictures" do
      expect(files_of.fetch("src/browser/blocks.js")).to include("const loadPicker = () => import(\"./media_picker.js\");")
    end

    it "mentions no name of this project in a template of the block list", :aggregate_failures do
      text = files_of.values_at("src/ui/blocks.ts", "src/ui/block_list.js", "src/browser/blocks.js").join
      names = [/\bPanels?\b/, /\bPageLayout/, /\bhero\b/, /\bsections?\b/i, /\barrangement/i]

      expect(names.map { |name| text.match?(name) }).to eq([false] * names.size)
    end
  end
end
