# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "hecks/tools/gate"

# The gate streams a start line and an end line per check as they happen, to the progress stream
# and never to the verdict on standard output.
RSpec.describe "Hecks::Tools::Gate progress" do
  let(:io) { StringIO.new }
  let(:progress) { Hecks::Tools::StageProgress.new(io) }
  let(:checks) do
    [{ "id" => "slow", "run" => ["sh", "-c", "sleep 0.2; echo one"] },
     { "id" => "quick", "run" => ["sh", "-c", "echo two; exit 3"] }]
  end

  def lines = io.string.lines.map(&:chomp)

  it "writes a start line for every check before its end line" do
    Hecks::Tools::Gate.run_all({ "env" => {} }, checks, Dir.pwd, progress)
    expect(lines.index("start slow")).to be < lines.index(lines.grep(/\Aok slow|\Afail slow/).first)
  end

  it "ends a failing check with its own fail line" do
    Hecks::Tools::Gate.run_all({ "env" => {} }, checks, Dir.pwd, progress)
    expect(lines).to include(a_string_starting_with("fail quick "))
  end

  it "reports a passing check with the time it took" do
    Hecks::Tools::Gate.run_all({ "env" => {} }, checks, Dir.pwd, progress)
    expect(lines.grep(/\Aok slow \d+\.\ds\z/).size).to eq(1)
  end

  it "keeps the verdict on standard output, not in the progress stream" do
    expect { Hecks::Tools::Gate.run_all({ "env" => {} }, checks, Dir.pwd, progress) }
      .not_to output.to_stdout
  end
end
