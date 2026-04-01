require "spec_helper"
require "hecks/extensions/web_explorer/renderer"

RSpec.describe Hecks::Conventions::ViewContract do
  describe "CONFIG contract" do
    let(:fields) { described_class::CONFIG[:fields] }

    it "includes structure_diagram as html" do
      field = fields.find { |f| f[:name] == :structure_diagram }
      expect(field).to eq(name: :structure_diagram, type: :html)
    end

    it "includes behavior_diagram as html" do
      field = fields.find { |f| f[:name] == :behavior_diagram }
      expect(field).to eq(name: :behavior_diagram, type: :html)
    end

    it "includes flows_diagram as html" do
      field = fields.find { |f| f[:name] == :flows_diagram }
      expect(field).to eq(name: :flows_diagram, type: :html)
    end

    it "maps html type to template.HTML in Go" do
      expect(described_class::GO_TYPES[:html]).to eq("template.HTML")
    end
  end

  describe "config template renders diagrams" do
    let(:views_dir) do
      File.expand_path("../../lib/hecks/extensions/web_explorer/views", __dir__)
    end

    let(:renderer) { Hecks::WebExplorer::Renderer.new(views_dir) }

    let(:html) do
      renderer.render(:config,
        skip_layout: true,
        title: "Config", brand: "Test", nav_items: [],
        roles: ["admin"], current_role: "admin",
        adapters: ["memory"], current_adapter: "memory",
        event_count: 0, booted_at: "now",
        policies: [], aggregates: [],
        structure_diagram: "classDiagram\n    class Pizza",
        behavior_diagram: "flowchart LR\n    subgraph Pizza",
        flows_diagram: "sequenceDiagram\n  participant Pizza")
    end

    it "renders mermaid pre tags for structure" do
      expect(html).to include('<pre class="mermaid">classDiagram')
    end

    it "renders mermaid pre tags for behavior" do
      expect(html).to include('<pre class="mermaid">flowchart LR')
    end

    it "renders mermaid pre tags for flows" do
      expect(html).to include('<pre class="mermaid">sequenceDiagram')
    end

    it "shows Domain Wiring heading" do
      expect(html).to include("<h2>Domain Wiring</h2>")
    end
  end
end
