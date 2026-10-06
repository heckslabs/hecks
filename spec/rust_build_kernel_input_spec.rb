require "spec_helper"
require "hecks/rust_build/kernel_input"

# The stdin a domain binary reads carries each command's declared argument defaults, as the Rust
# host's own table does, so a harness that runs the binary alone fills what Ruby fills.
RSpec.describe Hecks::RustBuild::KernelInput do
  let(:domain) { File.join(InMemoryDomain::ROOT, "qa/stress_domains/lease_clock") }
  let(:steps)  { [{ "verb" => "LeaseClock::Lease.Register", "args" => { "key" => { "value" => "a" } } }] }
  let(:board)  { "NestedPieces::Workspace.Board" }
  let(:nested_defaults) do
    { "#{board}.Retitle"     => { "label" => { "value" => "untitled" } },
      "#{board}.Card.Remark" => { "note" => { "text" => "none" } } }
  end

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
    expect(described_class.build(File.join(InMemoryDomain::ROOT, "examples/pizzas"), steps).keys).to eq(["steps"])
  end

  it "lists an entity's commands, and a nested entity's, under their full verb path" do
    nested = File.join(InMemoryDomain::ROOT, "qa/stress_domains/nested_pieces")

    expect(described_class.defaults_for(nested)).to eq(nested_defaults)
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
    pizzas = File.join(InMemoryDomain::ROOT, "examples/pizzas")

    expect(described_class.build(pizzas, steps)).to eq("steps" => steps)
  end

  it "adds no table for a domain with no generated IR" do
    expect(described_class.build("/no/such/domain", steps)).to eq("steps" => steps)
  end
end
