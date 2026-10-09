require "spec_helper"
require "json"

# `ask :name` in a policy resolves by the event's aggregate and the ask's name against the
# hecksagon's declared asks (ADR 0100), and dispatches exactly what the port-naming trigger it
# stands for did. The corpus-owned Errand domain and its frozen targets are spec/corpus/asks;
# rust/codegen/src/asks.rs holds the same targets against the Rust runtime's policy table.
RSpec.describe "a policy's ask" do
  ASK_CORPUS = File.join(InMemoryDomain::ROOT, "spec/corpus/asks").freeze

  def corpus(name) = JSON.parse(File.read(File.join(ASK_CORPUS, name)))

  def load_errand(hecksagon: File.join(ASK_CORPUS, "domain/bluebook/errand.hecksagon"))
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT,
       InMemoryDomain::MEMORY_ADAPTER, InMemoryDomain::PRISM_ADAPTER,
       File.join(ASK_CORPUS, "domain/bluebook/errand.bluebook"),
       hecksagon].each { |file| Kernel.load(file) }
    end
    registry
  end

  def booted_errand
    registry = load_errand
    registry.verify!
    Hecks::Runtime::Dispatcher.new(registry).dispatch_flat("Errand::Job.Request", ref: { value: "J1" })
    registry
  end

  def declared_targets(registry)
    registry.bluebook("Errand").policies.to_h { |policy| [policy.name, "Errand::#{policy.trigger_command}"] }
  end

  let(:registry) { booted_errand }

  it "resolves every ask to the target the corpus freezes" do
    expect(declared_targets(registry)).to eq(corpus("errand.json").fetch("targets"))
  end

  it "fires the resolved port operation, as the trigger it stands for did", :aggregate_failures do
    fired = registry.reaction_log.to_h { |reaction| [reaction[:policy], reaction[:trigger]] }

    expect(fired.fetch("RunWhenRequested")).to eq("Errand::Job::Worker.Run")
    expect(fired.fetch("AuditWhenRequested")).to eq("Errand::Job::Inspector.Audit")
  end

  it "carries the ask, not a port, on the IR policy row", :aggregate_failures do
    row = Hecks::Projector::Exporter.call(registry).fetch("Errand").fetch(:policies).first

    expect(row).to include(ask: "run")
    expect(row.key?(:trigger_command)).to be(false)
  end

  it "exports the same IR the corpus pins" do
    exported = Hecks::Projector::Exporter.call(registry).fetch("Errand")

    expect(JSON.parse(JSON.generate(exported))).to eq(corpus("errand.ir.json"))
  end

  it "leaves a trigger policy's row exactly as it was" do
    row = Hecks::Projector::Exporter.call(registry).fetch("Errand").fetch(:policies).last

    expect(row.keys).to eq(%i[name on_event trigger_command target_domain expect_undelivered where for_each
                              with_spec where_ast])
  end

  def refusal_of(fixture)
    load_errand(hecksagon: File.join(InMemoryDomain::ROOT, "spec/corpus/asks/variants", fixture)).verify!
  rescue Hecks::Runtime::WiringError => e
    e.message
  end

  it "keeps the hecksagon's ask_via pick through a second boot in one process" do
    expect { 2.times { Hecks.boot(File.join(ASK_CORPUS, "domain")) } }.not_to raise_error
  end

  it "refuses at boot an ask no hecksagon ask answers" do
    expect(refusal_of("errand_without_run.hecksagon")).to include("RunWhenRequested's ask :run matches no `asks`")
  end

  it "refuses at boot an ask declared on two ports with no ask_via" do
    expect(refusal_of("errand_unpicked.hecksagon")).to include('ask :run is asked on "Worker" and "Inspector"')
  end

  def build_policy_that_triggers_and_asks
    Hecks::Bluebook::DSL::PolicyBuilder.build("Both") do
      ask :c
      trigger "A.B"
    end
  end

  it "refuses a policy that both triggers and asks" do
    expect { build_policy_that_triggers_and_asks }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /both a trigger and an ask/)
  end
end
