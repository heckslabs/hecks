# frozen_string_literal: true

require "spec_helper"

require "hecks/pipeline_board/adapters/pipeline_web"

# The board's one design language: every page is served with the same style and the same
# navigation bar, and declares no colour of its own, so the pages cannot drift apart.
RSpec.describe Hecks::Adapters::PipelineBoard::Frame do
  let(:folder) { File.dirname(Hecks::Adapters::PipelineWeb::PAGE) }
  let(:pages) { Dir[File.join(folder, "*.html")] }

  it "puts the shared style where a page marks it" do
    styled = described_class.apply("<!--style--><style>main {}</style>")
    expect(styled).to start_with("<style>\n/* The board's one design language")
  end

  it "puts the same navigation bar into every page, in one order" do
    bar = described_class.apply("<header><!--nav--></header>")
    expect(bar.scan(/<a href="([^"]+)"/).flatten).to eq(%w[/ /sessions /plan /agents /ci /diagrams])
  end

  it "marks the page being read, and a run's own address as the sessions' page" do
    expect(described_class.nav).to include("aria-current", '<a href="/sessions" data-also="/runs/">Sessions</a>')
  end

  it "serves a page with neither mark as it is" do
    expect(described_class.apply("<p>plain</p>")).to eq("<p>plain</p>")
  end

  it "has every page mark where the shared style goes" do
    expect(pages.reject { |page| File.read(page).include?("<!--style--><style>") }).to be_empty
  end

  it "leaves no page declaring a colour of its own" do
    own = pages.select { |page| File.read(page).match?(/^\s*:root|--(page|surface|ink|good|critical): #/) }
    expect(own.map { |page| File.basename(page) }).to be_empty
  end

  it "defines each signal colour for the light theme and both dark ones" do
    style = File.read(described_class::STYLE)
    expect(style.scan(/--good: #\h{6}; --warning: #\h{6}; --critical: #\h{6}/).size).to eq(3)
  end
end
