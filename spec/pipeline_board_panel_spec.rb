# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_stages"
require_relative "support/pipeline_board_panel_state"

# The text panel the Snapshot query prints: a fixed state drawn at 80 and 120 columns, with and
# without colour, and a state whose sections could not be read.
RSpec.describe Hecks::Adapters::PipelineBoard::Panel do
  include PipelineBoardPanelState

  def lines(**options) = described_class.render(panel_state, **options).lines.map(&:chomp)

  def titles(**options) = lines(**options).grep(/\A\+- /).map { |line| line[/\A\+- (.*?) -/, 1] }

  def broken = { generated_at: "2026-11-07T12:00:00Z" }.merge(unreadable)

  def unreadable = %i[stages metrics ci_runs sessions open_work].to_h { |key| [key, { unknown: "gh down" }] }

  it "draws every box, top to bottom" do
    expect(titles).to eq(["Pipeline board 2026-11-07T12:00:00Z", "Stages", "Metrics", "Main CI", "Sessions", "Open train PRs",
                          "Planned work", "Agents"])
  end

  it "draws each line exactly as wide as asked, at 80 and at 120 columns", :aggregate_failures do
    [80, 120].each { |width| expect(lines(width: width).map(&:length).uniq).to eq([width]) }
  end

  it "holds the width to 60..200" do
    expect([lines(width: 10).first.length, lines(width: 900).first.length]).to eq([60, 200])
  end

  it "puts the stage counts in the header" do
    expect(lines[1]).to include("Work items 227/3/156", "Sessions 3", "Local main ahead 4")
  end

  it "lists the blocked sessions before the working and the done" do
    heads = lines.grep(/\A\| (blocked on you|working|done) \(/).map { |line| line[/\| (.*?) \(/, 1] }
    expect(heads).to eq(["blocked on you", "working", "done"])
  end

  it "names each session by its run, else its name, with its role and detail", :aggregate_failures do
    expect(lines).to include(a_string_matching(/board-snapshot \[coder\] writing the panel/))
    expect(lines).to include(a_string_matching(/planner-one \[planner\] which of two plans\?/))
  end

  it "marks each main CI run as passed, failed, running or other, oldest first" do
    expect(lines.join("\n")).to include("[+] a1a1a1a  [x] b2b2b2b  [~] c3c3c3c  [-] d4d4d4d")
  end

  it "shows a metric's value, its trend arrow and whether it is better", :aggregate_failures do
    expect(lines).to include(a_string_matching(/CI success\s+90 %\s+\^ \+20\.0 % better/))
    expect(lines).to include(a_string_matching(/Median CI wall\s+4\.2 min\s+v -2\.0 min better\s+goal 3 min/))
  end

  it "counts the checks of an open train pull request" do
    expect(lines).to include(a_string_matching(%r{#1272 train/main-5543822\s+89 checks: 87 passed, 2 failed, 0 pending}))
  end

  it "lists the first planned Work items only, and counts the rest", :aggregate_failures do
    shown = lines(limit: 2).grep(/Title of/)
    expect(shown.size).to eq(2)
    expect(lines(limit: 2)).to include(a_string_matching(/\+1 more planned/))
  end

  it "says what the reviews and the recommendations are" do
    expect(lines.join("\n")).to include("review alpha: sound", "review bravo: no verdict yet", "promotion recommended: 36f689057")
  end

  it "writes no colour unless asked" do
    expect(described_class.render(panel_state)).not_to include("\e[")
  end

  it "colours a row by its state when asked" do
    expect(described_class.render(panel_state, colour: true)).to include("\e[31m", "\e[32m", "\e[33m")
  end

  it "keeps the box edges aligned when it colours", :aggregate_failures do
    plain = described_class.render(panel_state, colour: false)
    painted = described_class.render(panel_state, colour: true).gsub(/\e\[\d+m/, "")
    expect(painted).to eq(plain)
  end

  it "says unknown with the reason for a section that could not be read, and draws the rest", :aggregate_failures do
    drawn = described_class.render(broken)
    expect(drawn.scan("unknown: gh down").size).to be >= 5
    expect(drawn).to include("+- Agents ")
  end

  it "draws an ASCII panel", :aggregate_failures do
    expect(described_class.render(panel_state)).to match(/\A[\x20-\x7e\n]+\z/)
  end
end
