require "spec_helper"
require "tmpdir"
require "hecks/closed_form"

# The gem reads a `.bluebook`, `.hecksagon`, `.world` or `.contextmap` file only through the closed
# form: the Rust parser admits the file's declarations and the gem evaluates the admitted text,
# so a file that carries code is refused before any of it runs.
RSpec.describe Hecks::ClosedForm do
  # Each file under lib/ and exe/ that evaluates or loads Ruby text, and what it reads.
  READERS = {
    "lib/hecks/closed_form.rb"                              => "the admitted text, and any other file `load_file` is given",
    "lib/hecks/persistence_legacy_fixture.rb"               => "the gem's own `.port` and `.adapter` files",
    "lib/hecks/projector/exporter/adapters.rb"              => "`.adapter` files",
    "lib/hecks/behaviors/runner.rb"                         => "`.behaviors` files",
    "lib/hecks/behaviors/expectations/adapter_selection.rb" => "`.adapter` files, their `require` lines left out",
    "lib/hecks/composer/agent.rb"                           => "the Composer's own `.port` and `.adapter`",
    "lib/hecks/forms/banking_presentation.rb"               => "the gem's own ports, adapters and the Forms example's `.rb`"
  }.freeze

  # A call that evaluates or loads Ruby text.
  EVALUATES = /Kernel\.load\(|Kernel\.eval\(|(?<![\w.])eval\(|instance_eval\(File|TOPLEVEL_BINDING\.eval|binding\.eval/

  def root = InMemoryDomain::ROOT

  def readers
    files = Dir.glob(File.join(root, "{lib/**/*.rb,exe/*}")).reject { |file| file.include?("/vendor/") }
    files.select { |file| File.read(file).match?(EVALUATES) }.map { |file| file.delete_prefix("#{root}/") }
  end

  def scratch(name, text)
    path = File.join(Dir.mktmpdir, name)
    File.write(path, text)
    path
  end

  it "is the only reader of declaration files: every other place that evaluates Ruby reads something else" do
    expect(readers).to match_array(READERS.keys)
  end

  it "never names a declaration file where any other reader loads one" do
    lines = READERS.keys.drop(1).flat_map { |file| File.readlines(File.join(root, file)).grep(EVALUATES) }
    expect(lines.grep(/\.(bluebook|hecksagon|world|contextmap)\b/)).to be_empty
  end

  it "refuses a bluebook that runs code, before any of it runs", :aggregate_failures do
    marker = File.join(Dir.mktmpdir, "ran")
    path = scratch("probe.bluebook", %(File.write(#{marker.inspect}, "x")\nHecks.bluebook "Probe" do\nend\n))
    expect { described_class.load(path) }.to raise_error(described_class::Refused, /probe\.bluebook:1/)
    expect(File).not_to exist(marker)
  end

  # Loads the given file through the closed form into a new registry beside the in-memory ports.
  def load_into_registry(path)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER].each { |file| Kernel.load(file) }
      described_class.load(path)
    end
    registry
  end

  it "declares what an admitted bluebook holds" do
    registry = load_into_registry(File.join(root, "examples/pizzas/bluebook/pizzas.bluebook"))
    expect(registry.bluebook("Pizzas").aggregates.map(&:name)).to include("Order")
  end

  it "declares what an admitted hecksagon wires" do
    path = scratch("probe.hecksagon", %(Hecks.hecksagon "Probe" do\n  persisted_by "Memory"\nend\n))
    expect(load_into_registry(path).hecksagons.keys).to eq(["Probe"])
  end

  it "loads any other file as Ruby" do
    marker = File.join(Dir.mktmpdir, "ran")
    described_class.load_file(scratch("probe.rb", %(File.write(#{marker.inspect}, "x")\n)))
    expect(File).to exist(marker)
  end
end
