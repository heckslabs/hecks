# frozen_string_literal: true

require "spec_helper"
require_relative "support/wiring_page_node"

# The wiring page's Graph view: a firing inside a context rings its block, a firing that reaches a
# port lights the line out to it, replays are marked and never written to the last-event line, and
# an ask row names its port.
RSpec.describe "the wiring page's firings" do
  graph = <<~JS
    const node = (id, kind, label, context) => ({ id, kind, label, domain: "Hecks", context, details: {} });
    applyWiring({ digest: "d", nodes: [node("Hecks::A", "aggregate", "A", "X"), node("Hecks::B", "aggregate", "B", "X"),
      node("Hecks::C", "aggregate", "C", "Y"), node("port:SourceTree", "port", "SourceTree", "X")],
      edges: [{ from: "Hecks::A", to: "Hecks::B", label: "Within", kind: "policy" },
              { from: "Hecks::A", to: "port:SourceTree", label: "Reads", kind: "ask" },
              { from: "Hecks::A", to: "Hecks::C", label: "Across", kind: "policy" }] }, true);
    const live = (policy) => ({ key: policy, name: "Ran", aggregate: "Hecks::A", at: "2026-01-01T00:00:00Z",
      reactions: [{ policy, command: "x", outcome: "delivered" }] });
  JS

  define_method(:scenario) { |body| WiringPageNode.run("#{graph}\n#{body}") }

  it "rings a block when a policy reacted inside it", :aggregate_failures do
    seen = scenario('fire(live("Within"), true, false); [units.get("Hecks / X").el.classList.contains("reacted")]')
    expect(seen).to eq([true])
  end

  it "does not ring a block for an event nothing followed" do
    seen = scenario(<<~JS)
      fire({ key: "k", name: "Ran", aggregate: "Hecks::A", reactions: [] }, true, false);
      units.get("Hecks / X").el.classList.contains("reacted")
    JS
    expect(seen).to be(false)
  end

  it "lights the line out to a port inside an opened context" do
    seen = scenario('enter("Hecks / X"); fire(live("Reads"), true, false); links.get("Hecks::A→port:SourceTree").el.classList.contains("lit")')
    expect(seen).to be(true)
  end

  it "marks a replayed firing and leaves the last-event line alone", :aggregate_failures do
    seen = scenario(<<~JS)
      const before = lastText(); fire(live("Across"), true, true);
      [lastText() === before, links.get("Hecks / X→Hecks / Y").el.classList.contains("replay")]
    JS
    expect(seen).to eq([true, true])
  end

  it "writes the last-event line for a live firing" do
    seen = scenario('fire(live("Across"), true, false); lastText().includes("Ran")')
    expect(seen).to be(true)
  end

  it "names the port an ask row reaches", :aggregate_failures do
    row = scenario("said(edges[1]).textContent")
    expect(row).to include("A asks the SourceTree port")
    expect(row).not_to include("asks a port")
  end
end
