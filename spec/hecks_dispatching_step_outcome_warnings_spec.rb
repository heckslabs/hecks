require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# A step's reason is the command's refusal, never the interpreter's warnings that came before it
# on stderr, so a launch that prints warnings is not read as a start that failed for them.
RSpec.describe Hecks::Adapters::Dispatching::StepOutcome, "#reason" do
  def outcome(err) = described_class.new(Hecks::Adapters::Shell::Result.new("", err, Struct.new(:success?).new(false)))

  it "gives the refusal behind the interpreter's warnings, not the warnings" do
    long = "/a/very/long/checkout/path/lib/hecks/version.rb:4: warning: already initialized constant Hecks::VERSION\n" * 4
    expect(outcome("#{long}[LifecycleRefused] Work.Start refused — status is started\n").reason)
      .to eq("[LifecycleRefused] Work.Start refused — status is started")
  end

  it "reads a refusal for another status as no claim held" do
    refused = outcome("[LifecycleRefused] Work.Start refused — status is done, and Start moves it\n")
    expect(refused.refused_at?("started")).to be(false)
  end
end
