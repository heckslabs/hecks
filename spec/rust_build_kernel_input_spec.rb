require "spec_helper"
require "tmpdir"
require "hecks/rust_build/kernel_input"
require_relative "support/generated_rust"
require_relative "support/kernel_input_fixtures"

# The stdin a domain binary reads carries each command's declared argument defaults, as the Rust
# host's own table does, so a harness that runs the binary alone fills what Ruby fills.
#
# The module reads a domain's generated `ir.json`. The examples feed it small IR fixtures written
# to a scratch Rust directory, so the logic is tested without the generated tree, which a fresh
# checkout does not carry; one group at the end reads the real tree to hold the fixtures to the
# IR the generator writes.
RSpec.describe Hecks::RustBuild::KernelInput do
  let(:rust_dir) { Dir.mktmpdir("hecks-kernel-input") }

  def domain = "qa/stress_domains/lease_clock"

  def steps = [{ "verb" => "LeaseClock::Lease.Register", "args" => { "key" => { "value" => "a" } } }]

  def board = "NestedPieces::Workspace.Board"

  def write_ir(feature, document)
    dir = File.join(rust_dir, "src", "generated", feature)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "ir.json"), JSON.generate(document))
  end

  before do
    write_ir("lease_clock", KernelInputFixtures.lease_clock)
    write_ir("nested_pieces", KernelInputFixtures.nested_pieces)
    write_ir("pizzas", KernelInputFixtures.pizzas)
    allow(Hecks::RustBuild).to receive(:rust_dir).and_return(rust_dir)
  end

  after { FileUtils.rm_rf(rust_dir) }

  it "lists a command's declared default under its qualified verb" do
    expect(described_class.defaults_for(domain)).to eq("LeaseClock::Lease.Reap" => { "grace" => { "value" => 0 } })
  end

  it "lists the facts a command needs and, apart, the facts a query needs, with their argument types", :aggregate_failures do
    tables = described_class.tables_for(domain)

    expect(tables["needs"]["LeaseClock::Lease.Reap"]).to eq([{ "fact" => "now", "type" => "LeaseInstant" }])
    expect(tables["query_needs"]).to eq("LeaseClock::Lease.Expired" => [{ "fact" => "now", "type" => "LeaseInstant" }])
    expect(tables["query_needs"].keys & tables["needs"].keys).to eq([])
  end

  it "sends each table only when it has an entry", :aggregate_failures do
    expect(described_class.build(domain, steps).keys).to eq(%w[steps defaults needs query_needs])
    expect(described_class.build("examples/pizzas", steps).keys).to eq(["steps"])
  end

  it "lists an entity's commands, and a nested entity's, under their full verb path" do
    expect(described_class.defaults_for("qa/stress_domains/nested_pieces")).to eq(
      "#{board}.Retitle"     => { "label" => { "value" => "untitled" } },
      "#{board}.Card.Remark" => { "note" => { "text" => "none" } }
    )
  end

  it "builds the input from the steps and the defaults table", :aggregate_failures do
    input = described_class.build(domain, steps)

    expect(input["steps"]).to eq(steps)
    expect(input["defaults"]).to eq("LeaseClock::Lease.Reap" => { "grace" => { "value" => 0 } })
  end

  it "renders the same input as JSON for a binary's stdin" do
    expect(JSON.parse(described_class.json(domain, steps))).to eq(described_class.build(domain, steps))
  end

  it "adds no table for a domain whose commands declare no default" do
    expect(described_class.build("examples/pizzas", steps)).to eq("steps" => steps)
  end

  it "adds no table for a domain with no generated IR" do
    expect(described_class.build("/no/such/domain", steps)).to eq("steps" => steps)
  end

  describe "against the IR the generator really writes" do
    include_context "with the generated Rust tree"

    before { allow(Hecks::RustBuild).to receive(:rust_dir).and_call_original }

    it "reads the same tables from the generated lease_clock IR", :aggregate_failures do
      real = File.join(InMemoryDomain::ROOT, "qa/stress_domains/lease_clock")

      expect(described_class.defaults_for(real)).to eq("LeaseClock::Lease.Reap" => { "grace" => { "value" => 0 } })
      expect(described_class.tables_for(real)["query_needs"].keys).to eq(["LeaseClock::Lease.Expired"])
    end

    it "reads the same nested paths from the generated nested_pieces IR" do
      real = File.join(InMemoryDomain::ROOT, "qa/stress_domains/nested_pieces")

      expect(described_class.defaults_for(real).keys).to contain_exactly("#{board}.Retitle", "#{board}.Card.Remark")
    end
  end
end
