require "spec_helper"

# The era check's timeout and the runtime baseline's worker count are declared once, on the
# bluebook commands that dispatch them; the launchers behind them hold no copy.
RSpec.describe "launcher defaults declared on their bluebook commands" do
  before(:all) do
    @runtime = boot_hecks_in_memory
  end

  def command(aggregate, name) = @runtime.registry.bluebook("Hecks").aggregate(aggregate).command(name)

  def default_of(command, name) = command.attributes.find { |attribute| attribute.name == name }.default

  def help(*verb)
    Hecks::Adapters::Driving::CliRunner.call(runtime: @runtime, argv: [*verb, "--help"], program: "hecks").first
  end

  it "gives CheckEra and Recheck a timeout of ten seconds", :aggregate_failures do
    expect(default_of(command("Host", "CheckEra"), :timeout)).to eq(10)
    expect(default_of(command("Host", "Recheck"), :timeout)).to eq(10)
  end

  it "shows each default in the command's own help", :aggregate_failures do
    expect(help("host.check_era")).to match(/timeout\.value\s+Float; defaults to 10; optional/)
    expect(help("host.recheck")).to match(/timeout\.value\s+Float; defaults to 10; optional/)
  end

  it "has the era check's library take its timeout from the caller" do
    expect { Hecks::Tools::CheckEra.assess("http://127.0.0.1:1", "/no/such/eras") }.to raise_error(ArgumentError, /timeout/)
  end
end
