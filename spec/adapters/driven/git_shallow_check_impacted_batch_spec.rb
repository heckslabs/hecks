# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/delivery_library"
Hecks::Adapters::DeliveryLibrary.require("git_landing")
require "hecks/hecks/adapters/git_shallow_check"

# The launcher call for a batch, and how a refusal names what failed.
RSpec.describe Hecks::Adapters::GitShallowCheck::ImpactedBatch, ".call" do
  Result = Struct.new(:out, :err, :exit_code) do
    def ok? = exit_code.zero?
  end

  def shell(out, code)
    Object.new.tap { |one| one.define_singleton_method(:capture) { |*_argv, **_opts| Result.new(out, "", code) } }
  end

  def refusal(text) = { "state" => { "refusal" => text } }.to_json

  it "passes on a green report" do
    green = { "state" => { "report" => "files:\n  a: 1 example, 0 failures\n1 example, 0 failures" } }.to_json
    expect { described_class.call(shell(green, 0), ".", %w[a b]) }.not_to raise_error
  end

  it "says the launcher stopped the call when it ran past its bound, not only the exit code" do
    line = "stopped: ran past the 600-second bound (file_seconds) in spec/a_spec.rb, example \"x\""
    expect { described_class.call(shell(refusal("a: 1 example, 0 failures\n#{line}"), 1), ".", %w[a]) }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /failing spec: stopped: ran past the 600-second bound/)
  end

  it "names the exit code when no stopped line is said" do
    expect { described_class.call(shell(refusal("boom"), 1), ".", %w[a b]) }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /failing spec: exit 1 in a b/)
  end

  it "names the failing file and example in the middle of a batch" do
    text = "rspec ./spec/b_spec.rb:12 # B does it\n\nfailed: spec/b_spec.rb (1 of 3 files)\n3 examples, 1 failure"
    expect { described_class.call(shell(refusal(text), 1), ".", %w[a b c]) }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, %r{failing spec: \./spec/b_spec.rb:12 # B does it})
  end
end
