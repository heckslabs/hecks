require "spec_helper"
require "hecks/cli/run"

# An adapter behind a declared port reaches its domain through the Ruby constants the driving
# adapter installs, so a verb run of a domain with ports must install them (or the adapter is
# refused with `uninitialized constant` and the run records that as the domain's own failure).
RSpec.describe Hecks::CLI::Run, ".cli_form" do
  let(:runtime) { instance_double(Hecks::Runtime::Dispatcher, registry: registry) }

  before do
    allow(Hecks).to receive(:boot).and_return(runtime)
    allow(Hecks::Assembly).to receive(:bind_runtime)
    allow(Hecks::Adapters::Driving::CliRunner).to receive(:call).and_return(["done", 0])
  end

  def run_verb
    expect { described_class.cli_form("domain", ["noop"], "hecks run") }.to raise_error(SystemExit).and output.to_stdout
  end

  context "when the domain declares a port" do
    let(:registry) { double("registry", ports: { "Thinker" => Object.new }) } # rubocop:disable RSpec/VerifiedDoubles

    it "installs the Ruby driving adapter" do
      run_verb

      expect(Hecks::Assembly).to have_received(:bind_runtime).with(runtime)
    end
  end

  context "when the domain declares no port" do
    let(:registry) { double("registry", ports: {}) } # rubocop:disable RSpec/VerifiedDoubles

    it "keeps the cheaper boot" do
      run_verb

      expect(Hecks::Assembly).not_to have_received(:bind_runtime)
    end
  end
end
