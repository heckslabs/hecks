require "hecks"
require_relative "support/postgres_probe"

# `aggregate "ProbeRun", kind: "Run"` evaluates lib/hecks/language/kinds/run.kind around the body,
# so an aggregate states what is its own and takes the run lifecycle from the kind.
RSpec.describe "an aggregate of a kind" do
  def build_bluebook(&block)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Hecks.bluebook("Probe", &block)
    end
    registry.bluebook("Probe")
  end

  def probe_run(kind: "Run")
    build_bluebook do
      aggregate "ProbeRun", kind: kind do
        description "One probe of the tree."
        command("Probe") { role "Maintainer" and emits ProbeRequested }
      end
    end.aggregate("ProbeRun")
  end

  it "takes the run lifecycle from the kind" do
    expect(probe_run.lifecycle.default).to eq("requested")
  end

  it "keeps its own commands before the kind's bookkeeping commands" do
    expect(probe_run.commands.map(&:hecks_name)).to eq(%w[Probe Accept Complete Fault])
  end

  it "names the bookkeeping events for the aggregate's stem" do
    expect(probe_run.commands.last(3).flat_map(&:emits)).to eq(%w[ProbeAccepted ProbeCompleted ProbeFaulted])
  end

  it "adds the two queries that read how requests ended" do
    expect(probe_run.queries.map(&:name)).to eq(%w[ProbeOutcome ProbeFaulted])
  end

  it "carries the policies that examine, accept, perform and record a request" do
    expect(probe_run.policies.map(&:name)).to include("AcceptProbeWhenExamined", "RecordProbeOutcome")
  end

  it "refuses a kind that has no file" do
    expect { probe_run(kind: "Missing") }.to raise_error(Hecks::Bluebook::DSL::Malformed, /kind "Missing".*missing\.kind/)
  end

  it "builds an aggregate with no kind from its body alone", :aggregate_failures do
    plain = build_bluebook { aggregate("PlainRun") { identified_by :run_id } }.aggregate("PlainRun")
    expect(plain.commands).to be_empty
  end
end
