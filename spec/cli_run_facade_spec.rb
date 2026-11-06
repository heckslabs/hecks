require "spec_helper"
require "hecks/tools/run"

# A verb run boots without the Ruby facade, so it binds it for a domain that declares ports (or an
# adapter behind a port is refused with `uninitialized constant`, and the run records that as the
# domain's own failure).
RSpec.describe Hecks::Tools::Run, ".cli_form" do
  let(:runtime) { instance_double(Hecks::Runtime::Dispatcher) }

  before do
    allow(Hecks).to receive(:boot).and_return(runtime)
    allow(Hecks::Assembly).to receive(:bind_ported_runtime)
    allow(Hecks::Adapters::Driving::CliRunner).to receive(:call).and_return(["done", 0])
    allow(Hecks::Adapters::Driving::CliRunner).to receive(:resolve).and_return({})
    silence_the_answer
  end

  def silence_the_answer
    allow(described_class).to receive(:puts)
    allow(described_class).to receive(:exit).and_raise(SystemExit)
  end

  def run_verb
    described_class.cli_form("domain", ["noop"], "hecks run")
  rescue SystemExit
    nil
  end

  it "binds the Ruby facade of the booted domain" do
    run_verb

    expect(Hecks::Assembly).to have_received(:bind_ported_runtime).with(runtime)
  end

  it "writes a verb that names a command, with the bang the launcher requires" do
    run_verb

    expect(Hecks::Adapters::Driving::CliRunner).to have_received(:call).with(hash_including(argv: ["noop!"]))
  end

  it "leaves a verb that names a query as typed, since a query only reads" do
    allow(Hecks::Adapters::Driving::CliRunner).to receive(:resolve).and_return({ asking: true })

    described_class.cli_form("domain", ["workspace.status", "checkout=."], "hecks run")
  rescue SystemExit
    expect(Hecks::Adapters::Driving::CliRunner).to have_received(:call)
      .with(hash_including(argv: ["workspace.status", "checkout=."]))
  end
end
