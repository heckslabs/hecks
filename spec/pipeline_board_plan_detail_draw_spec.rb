# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_web"

# A Work item's detail on the planning page: the whole text sits in a closed details element.
RSpec.describe Hecks::Adapters::PipelineBoard::PlanDetail, ".draw" do
  def long = "#{"Observed facts go on and on " * 4}. #{"More text. " * 270}"

  def row(detail)
    { slug: "a", title: "T", lane: "now", status: "planned", priority: "now", area: [], reviewed: [], detail: detail }
  end

  it "keeps the whole detail inside a closed details element", :aggregate_failures do
    html = described_class.draw(row(long))
    expect(html).to start_with("<details class=\"detail\"><summary>")
    expect(html).not_to include(" open")
    expect(html).to include("<pre>#{long.strip}</pre>")
  end

  it "draws nothing for an empty detail" do
    expect(described_class.draw(row(" "))).to eq("")
  end

  it "escapes the markup in a detail", :aggregate_failures do
    html = described_class.draw(row("Fix <b> & \"q\"."))
    expect(html).to include("&lt;b&gt; &amp; &quot;q&quot;.")
    expect(html).not_to include("<b>")
  end

  it "renders a page of 60 items without visible detail text", :aggregate_failures do
    html = Array.new(60) { |i| Hecks::Adapters::PipelineBoard::PlanItem.draw(row(long).merge(slug: "s#{i}")) }.join
    expect(html.gsub(%r{<details class="detail">.*?</details>}m, "")).not_to include("Observed facts")
    expect(html.scan("<details class=\"detail\">").size).to eq(60)
  end
end
