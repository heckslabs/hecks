require "spec_helper"
require_relative "../support/memory_ports"

# The launcher's flags are taken from every command, opted in or not; a flag no command declares
# is refused with exit 2 that names it (ADR 0163 step 17).
RSpec.describe Hecks::Adapters::Driving::CliRunner do
  let(:runtime) { boot_in_memory }

  def run(*argv) = described_class.call(runtime: runtime, argv: argv, program: "hecks run")
  def status(*argv) = run(*argv).last

  def create_pizza(*extra)
    run("order.create_pizza!", "name=Margherita", "pizza.price_cents.cents=1200", "pizza.size.value=large", *extra)
  end

  it "accepts --wait on a command whose bluebook does not opt into the launcher" do
    expect(create_pizza("--wait").last).to eq(Hecks::Adapters::Driving::ExitStatus::ANSWERED)
  end

  it "takes --wait out of the words the command reads" do
    expect(create_pizza("--wait").first).not_to include("wait")
  end

  it "refuses a flag no command declares, with exit 2 and the flag named" do
    text, code = run("order.create_pizza!", "name=X", "--bogus")
    expect([code, text]).to match([2, /--bogus is a flag/])
  end
end
