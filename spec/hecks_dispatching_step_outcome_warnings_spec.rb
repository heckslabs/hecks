require "spec_helper"
require "hecks/hecks/adapters/dispatching"
require "hecks/runtime/refusal_wording"

# A step's reason is the command's refusal, never the interpreter's warnings that came before it
# on stderr, so a launch that prints warnings is not read as a start that failed for them.
RSpec.describe Hecks::Adapters::Dispatching::StepOutcome, "#reason" do
  let(:warnings) do
    "/a/very/long/checkout/path/lib/hecks/version.rb:4: warning: already initialized constant Hecks::VERSION\n" * 4
  end

  def outcome(err) = described_class.new(Hecks::Adapters::Shell::Result.new("", err, Struct.new(:success?).new(false)))

  # The refusal the launcher prints for a Start on a work item at `current`: the code in brackets,
  # then the runtime's own `transition_blocked` wording.
  def refusal(current)
    wording = Hecks::Runtime::RefusalWording.render_site("LifecycleRefused", "transition_blocked",
                                                         command: "Start", field: "status",
                                                         current: Hecks::Rendering.describe(current), allowed: ["planned"])
    "[#{Hecks::Runtime::LifecycleRefused.new.code}] #{wording}"
  end

  it "gives the refusal behind the interpreter's warnings, not the warnings" do
    expect(outcome("#{warnings}#{refusal("started")}\n").reason).to eq(refusal("started")[0, 300])
  end

  it "reads the real refusal of a second Start behind the warnings as a claim already held" do
    expect(outcome("#{warnings}#{refusal("started")}\n").refused_at?("started")).to be(true)
  end

  it "reads a refusal for another status as no claim held" do
    expect(outcome("#{warnings}#{refusal("finished")}\n").refused_at?("started")).to be(false)
  end
end
