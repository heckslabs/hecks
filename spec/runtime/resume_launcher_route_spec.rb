require "spec_helper"

# How the launcher routes `resume <run>`: the usage path and the stream check both leave it alone,
# so the one booted `call` runs it, once. Neither is given a runtime it could resolve the line with.
RSpec.describe Hecks::Adapters::Driving::CliRunner do
  let(:unbooted) { Object.new }

  it "answers nothing on the usage path for a resume that names a run, so the launcher boots" do
    expect(described_class.usage(runtime: unbooted, argv: %w[resume r1])).to be_nil
  end

  it "does not resolve a resume when asked whether the line is a stream" do
    expect(described_class.stream(runtime: unbooted, argv: %w[resume r1])).to be_nil
  end

  it "takes a resume that names a run as a line that runs a saga" do
    expect(described_class.runs_a_saga?(%w[resume r1])).to be(true)
  end

  it "takes a resume with no run, or one that asks for help, as a request for usage", :aggregate_failures do
    expect(described_class.runs_a_saga?(%w[resume])).to be(false)
    expect(described_class.runs_a_saga?(%w[resume r1 --help])).to be(false)
  end
end
