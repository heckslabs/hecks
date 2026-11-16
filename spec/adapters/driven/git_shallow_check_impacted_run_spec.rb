# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/delivery_library"
Hecks::Adapters::DeliveryLibrary.require("git_landing")
require "hecks/hecks/adapters/git_shallow_check"

# The impacted-spec run takes its files a batch at a time, one launcher call each, with the files
# that load the whole library last; it stops at the world's budget between batches and returns the
# files it left, and a red file refuses by name.
RSpec.describe Hecks::Adapters::GitShallowCheck::ImpactedRun, "#call" do
  let(:batch) { Hecks::Adapters::GitShallowCheck::ImpactedBatch }
  let(:specs) { %w[spec/a_spec.rb spec/load_hygiene_lib_1_spec.rb spec/b_spec.rb] }
  let(:seen) { [] }

  def build(clock: -> { 0 }, width: 1, files: specs)
    described_class.new(Dir.pwd, budget: 600, clock: clock, workers: ->(_count) { width }).tap do |run|
      allow(run).to receive(:mapped).and_return(files)
      allow(batch).to receive(:call) { |_shell, _dir, group| seen << group }
    end
  end

  def many(count) = Array.new(count) { |index| "spec/f#{index}_spec.rb" }

  it "runs the files in one call each batch, not one each file", :aggregate_failures do
    done = build(files: many(9)).call([], "main")
    expect(done.calls).to eq(3)
    expect(seen.map(&:size)).to eq([4, 4, 1])
  end

  it "reports every file as run" do
    expect(build.call([], "main").ran).to match_array(specs)
  end

  it "runs several workers' batches" do
    expect(build(width: 3, files: many(9)).call([], "main").ran).to match_array(many(9))
  end

  it "stops before the next batch once the budget has passed", :aggregate_failures do
    ticks = Queue.new([0, 0, 700, 700])
    done = build(clock: -> { ticks.pop }, files: many(9)).call([], "main")
    expect(done.ran).to eq(many(9).first(4))
    expect(done.unrun).to eq(many(9).last(5))
  end

  it "raises the failing file and example by name" do
    run = build
    allow(batch).to receive(:call).and_raise(Hecks::Adapters::ConsoleCapture::Failure, "impacted specs red: x")
    expect { run.call([], "main") }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /red: x/)
  end
end
