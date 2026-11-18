require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/main_verification"

# The spec files a failed verification's logs name are what the search for the first bad merge
# probes.
RSpec.describe Hecks::Adapters::MainIntegration::FailureLog do
  let(:directory) { Dir.mktmpdir("hecks-failure-log") }

  after { FileUtils.remove_entry(directory) }

  it "names every distinct spec file an output mentions", :aggregate_failures do
    output = "rspec spec/a_spec.rb\n./spec/b_spec.rb:12\nfailing spec: spec/a_spec.rb # x"
    expect(described_class.specs(output)).to eq(%w[spec/a_spec.rb spec/b_spec.rb])
    expect(described_class.specs("nothing here")).to eq([])
  end

  it "reads the spec files back from the logs kept for one landing", :aggregate_failures do
    log = described_class.new(directory)
    log.keep("abcdef1234567", "quick gate", ["gate"], "rspec spec/a_spec.rb")
    log.keep("0000000000000", "quick gate", ["gate"], "rspec spec/other_spec.rb")
    expect(log.specs_for("abcdef1234567")).to eq(["spec/a_spec.rb"])
    expect(log.specs_for("ffffffffff")).to eq([])
  end
end
