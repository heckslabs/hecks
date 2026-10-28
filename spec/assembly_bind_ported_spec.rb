require "spec_helper"

# An adapter behind a declared port reaches its domain through the Ruby constants the driving
# adapter installs, so a run that boots without them installs them for a domain with ports and
# leaves a domain with none on the cheaper boot.
RSpec.describe Hecks::Assembly, ".bind_ported_runtime" do
  let(:dispatcher) { instance_double(Hecks::Runtime::Dispatcher, registry: registry) }

  before { allow(described_class).to receive(:bind_runtime) }

  context "when the domain declares a port" do
    let(:registry) { instance_double(Hecks::Runtime::Registry, ports: { "Thinker" => Object.new }) }

    it "installs the Ruby driving adapter" do
      described_class.bind_ported_runtime(dispatcher)

      expect(described_class).to have_received(:bind_runtime).with(dispatcher)
    end
  end

  context "when the domain declares no port" do
    let(:registry) { instance_double(Hecks::Runtime::Registry, ports: {}) }

    it "keeps the cheaper boot" do
      described_class.bind_ported_runtime(dispatcher)

      expect(described_class).not_to have_received(:bind_runtime)
    end
  end
end
