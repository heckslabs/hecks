# frozen_string_literal: true

require "spec_helper"
require "hecks/tools/gate"

RSpec.describe Hecks::Tools::Gate, ".run_one worker count" do
  let(:printer) { { "run" => ["sh", "-c", "printf %s \"$PARALLEL_PROCESSOR_COUNT\""] } }

  def count_of_check(continuous:, parent: nil)
    saved = ENV.to_h.slice("CI", "PARALLEL_PROCESSOR_COUNT")
    ENV["CI"] = continuous
    ENV["PARALLEL_PROCESSOR_COUNT"] = parent
    described_class.run_one(printer, {}, Dir.pwd).first
  ensure
    %w[CI PARALLEL_PROCESSOR_COUNT].each { |name| ENV[name] = saved[name] }
  end

  it "holds a check's parallel workers to the gate's worker count outside CI" do
    expect(count_of_check(continuous: nil)).to eq(described_class.workers(Dir.pwd).to_s)
  end

  it "keeps a count a parent set when it is lower" do
    expect(count_of_check(continuous: nil, parent: "1")).to eq("1")
  end

  it "leaves the runner's full width alone in CI" do
    expect(count_of_check(continuous: "true")).to eq("")
  end
end
