require "spec_helper"

# `hecks test_suite_run.stress_concurrency` takes its default run count and first seed from its bluebook command,
# the one place they are written; the launcher behind it holds no copy.
RSpec.describe "stress_concurrency's declared defaults" do
  before(:all) do
    @runtime = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_doors: false)
  end

  let(:command) do
    @runtime.registry.bluebook("Hecks").aggregate("TestSuiteRun").command("StressConcurrency")
  end

  def default_of(name) = command.attributes.find { |attribute| attribute.name == name }.default

  it "declares thirty runs and a first seed of one" do
    expect(default_of(:runs)).to eq(30)
    expect(default_of(:seed_start)).to eq(1)
  end

  it "leaves the parallelism to the machine, which no fixed default can say" do
    expect(default_of(:parallel)).to be_nil
    expect(command.attributes.find { |attribute| attribute.name == :parallel }).to be_optional
  end

  it "shows the defaults in the command's own help" do
    help = Hecks::Doors::CliRunner.call(runtime: @runtime, argv: %w[test_suite_run.stress_concurrency --help],
                                        program: "hecks").first

    expect(help).to match(/runs\.value\s+Integer; defaults to 30; optional/)
    expect(help).to match(/seed_start\.value\s+Integer; defaults to 1; optional/)
  end
end
