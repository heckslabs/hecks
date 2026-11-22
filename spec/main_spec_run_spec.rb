# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/main_spec_run"

# How a first spec reads when main runs it: one that does not load on main is errored,
# never passed.
RSpec.describe Hecks::Adapters::MainSpecRun do
  let(:ok)     { Struct.new(:success?, :exitstatus).new(true, 0) }
  let(:red)    { Struct.new(:success?, :exitstatus).new(false, 1) }
  let(:shell)  { instance_double(Hecks::Adapters::Shell) }

  def answer(out, status) = Hecks::Adapters::Shell::Result.new(out, "", status)

  def launcher_says(out, status)
    allow(shell).to receive(:capture) { |*cmd, **| cmd.include?("--wait") ? answer(out, status) : answer("", ok) }
  end

  def read_run = described_class.new(shell: shell).call("/repo", "abc", ["spec/a_spec.rb"])

  it "reads a spec that does not load on main as errored" do
    launcher_says("Finished in 0.01 seconds\n0 examples, 0 failures\n", red)
    expect(read_run).to eq(first_spec: "errored", first_example: "")
  end

  it "reads a failing example as failed and names it" do
    launcher_says("1 example, 1 failure\nrspec ./spec/a_spec.rb:2 # a fails\n", red)
    expect(read_run).to eq(first_spec: "failed", first_example: "a fails")
  end

  it "reads a green example as passed" do
    launcher_says("1 example, 0 failures\n", ok)
    expect(read_run).to eq(first_spec: "passed", first_example: "")
  end

  it "reads a run with no example, or a red exit with none failing, as errored", :aggregate_failures do
    launcher_says("0 examples, 0 failures\n", ok)
    expect(read_run).to include(first_spec: "errored")
    launcher_says("3 examples, 0 failures\n", red)
    expect(read_run).to include(first_spec: "errored")
  end
end
