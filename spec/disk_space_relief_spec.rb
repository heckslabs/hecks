require "spec_helper"
require_relative "support/disk_space_rows"

# What the DiskSpace bluebook frees, what it never touches, and the caches it can clear.
RSpec.describe "the DiskSpace relief and caches", :aggregate_failures do
  include DiskSpaceRows

  def protected_states = rows("Reading", "ReadingState").select { |row| row[:protected] == "yes" }.map { |row| row[:state] }

  it "protects unpushed, dirty, pinned and live subjects" do
    expect(protected_states).to eq(%w[pinned live unpushed dirty])
  end

  it "frees a merged worktree with Landing.Retire and a done run with AgentRun.Tidy, both automatic at high" do
    auto = rows("Relief", "ReliefRule").select { |row| row[:auto] == "high" }

    expect(auto.map { |row| [row[:kind], row[:command]] }).to eq([%w[worktree Landing.Retire], %w[run AgentRun.Tidy]])
  end

  it "never relieves a cache or a tmp orphan unasked" do
    unasked = rows("Relief", "ReliefRule").select { |row| %w[cache tmp].include?(row[:kind]) }

    expect(unasked.map { |row| row[:auto] }).to eq(%w[never never])
  end

  it "relieves only at high and only when confirmed" do
    expect(givens("Relief", "Relieve")).to match([/only at the high level/, /only with --confirm/])
  end

  it "declares no second copy of the Retire or Tidy givens" do
    expect(givens("Relief", "Plan")).to be_empty
  end

  it "reads a done run with the same vocabulary the relief rule uses" do
    states = rows("Reading", "ReadingState").map { |row| row[:state] }

    expect(rows("Relief", "ReliefRule").map { |row| row[:state] } - states).to eq([])
  end
end
