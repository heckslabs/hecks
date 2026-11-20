require "spec_helper"
require "hecks/rust_build/kernel_hello"
require "hecks/rust_build/kernel_input"

# The hello a kernel client sends is built from the described registry's IR, and a fact the
# kernel asks for is answered from the registry's clock port, so a clock a spec binds is the one
# the kernel sees. The registry's tables hold every bluebook it loaded; the generated `ir.json`
# holds the target domain alone, so the first are a superset of the second.
RSpec.describe Hecks::RustBuild::KernelHello do
  # A fixed clock, bound in place of the system clock: the answer must be its reading.
  module KernelHelloFixedClock
    module_function

    def now = 5_000
  end

  def registry_of(path) = Hecks.describe(File.expand_path("../#{path}", __dir__)).registry

  def generated_tables(path) = Hecks::RustBuild::KernelInput.tables_for(path)

  def superset?(wide, narrow)
    narrow.all? do |name, table|
      table.is_a?(Hash) ? table <= wide.fetch(name) : (table - wide.fetch(name)).empty?
    end
  end

  let(:lease_clock) { registry_of("qa/stress_domains/lease_clock") }

  %w[qa/stress_domains/lease_clock examples/pizzas].each do |path|
    it "builds the same tables from #{path}'s registry as from its generated IR" do
      expect(described_class.tables(registry_of(path))).to eq(generated_tables(path))
    end
  end

  it "builds a superset of banking's generated tables, with the attached domains' verbs too" do
    expect(superset?(described_class.tables(registry_of("examples/banking")), generated_tables("examples/banking"))).to be(true)
  end

  describe "the answerer" do
    before { stub_const("Hecks::Adapters::SystemClock", KernelHelloFixedClock) }

    let(:answerer) { described_class.answerer(lease_clock) }

    it "answers now from the bound clock, bare for an Integer argument" do
      expect(answerer.call("now", "Integer", "LeaseClock::Lease.Acquire")).to eq(5_000)
    end

    it "answers now as a one-field value object for any other type" do
      expect(answerer.call("now", "LeaseInstant", "LeaseClock::Lease.Acquire")).to eq("value" => 5_000)
    end

    it "answers today as whole days since the epoch" do
      expect(answerer.call("today", "Integer", "LeaseClock::Lease.Acquire")).to eq(0)
    end

    it "is answered nil for a fact the host does not answer" do
      expect(answerer.call("identity_generation", "String", "LeaseClock::Lease.Acquire")).to be_nil
    end
  end

  describe "the filler" do
    before { stub_const("Hecks::Adapters::SystemClock", KernelHelloFixedClock) }

    let(:fill) { described_class.filler(lease_clock, described_class.tables(lease_clock)) }

    def acquire(args) = { "verb" => "LeaseClock::Lease.Acquire", "args" => args }

    it "fills a needed clock fact the step leaves out from the bound clock" do
      expect(fill.call(acquire("key" => "a"))["args"]).to eq("key" => "a", "now" => { "value" => 5_000 })
    end

    it "keeps a needed fact the caller named" do
      expect(fill.call(acquire(now: { value: 42 }))["args"]).to eq(now: { value: 42 })
    end

    it "fills a step addressed with to and with in its with" do
      step = { "verb" => "LeaseClock::Lease.Acquire", "to" => "a", "with" => {} }
      expect(fill.call(step)["with"]).to eq("now" => { "value" => 5_000 })
    end

    it "fills a query's needs from the query table" do
      expect(fill.call("query" => "LeaseClock::Lease.Expired", "args" => {})["args"]).to eq("now" => { "value" => 5_000 })
    end

    it "leaves a message that is not a step as it was" do
      expect(fill.call("instances" => true)).to eq("instances" => true)
    end
  end
end
