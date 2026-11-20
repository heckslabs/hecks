require "spec_helper"
require "hecks/hecks/adapters/operation_run"

# A verb run boots without the Ruby facade, so it binds it for a domain that declares ports (or an
# adapter behind a port is refused with `uninitialized constant`, and the run records that as the
# domain's own failure).
RSpec.describe Hecks::Adapters::OperationRun, ".cli_form" do
  let(:runtime) { instance_double(Hecks::Runtime::Dispatcher) }

  before do
    allow(Hecks).to receive(:boot).and_return(runtime)
    allow(Hecks::Assembly).to receive(:bind_ported_runtime)
    allow(Hecks::Adapters::Driving::CliRunner).to receive(:call).and_return(["done", 0])
  end

  it "binds the Ruby facade of the booted domain" do
    described_class.cli_form("domain", ["noop"], "hecks run")

    expect(Hecks::Assembly).to have_received(:bind_ported_runtime).with(runtime)
  end

  it "answers the verb's text" do
    expect(described_class.cli_form("domain", ["noop"], "hecks run")).to eq("done")
  end
end
