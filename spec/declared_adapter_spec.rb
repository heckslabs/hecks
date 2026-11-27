require "spec_helper"
require "tmpdir"
require "hecks/behaviors"
require_relative "support/hecks_parse_binary"

# An `.adapter` that answers its port from `replies` and `refuses` rows, with no Ruby behind it
# (ADR 0238). The corpus-owned Courier domain is spec/corpus/declared: one port, a Carrier, and two
# declared carriers beside its suite, so the suite runs once per carrier and is the port's contract.
RSpec.describe "a declared adapter", :io do
  include_context "with the hecks-parse binary"

  COURIER = File.join(InMemoryDomain::ROOT, "spec/corpus/declared/domain/bluebook").freeze
  SUITE = File.join(COURIER, "courier.behaviors").freeze

  def carrier(name) = File.join(COURIER, "behavior_adapters", "#{name}_carrier.adapter")

  def boot(adapter)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER, File.join(COURIER, "courier.bluebook"), File.join(COURIER, "courier.hecksagon"),
       adapter].each { |file| Kernel.load(file) }
    end
    registry.tap(&:verify!)
  end

  def book(adapter, destination)
    registry = boot(carrier(adapter))
    dispatcher = Hecks::Runtime::Dispatcher.new(registry)
    booked = dispatcher.dispatch_flat("Courier::Parcel.Book", ref: { value: "P-1" }, destination: { value: destination })
    [dispatcher, registry.bluebook("Courier").aggregates.first, booked]
  end

  def booked(adapter, destination) = book(adapter, destination).first.events.map(&:name)

  def parcel(adapter, destination)
    dispatcher, aggregate, booked = book(adapter, destination)
    Hecks::Runtime::Value.materialize(dispatcher.repository("Courier", aggregate).find(booked.id).state)
  end

  def answered(adapter, **asked)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) { Kernel.load(carrier(adapter)) }
    Hecks::Runtime::DeclaredAdapter.class_for(registry.adapters.values.first).new.collect(**asked)
  end

  def rates(adapter, destination)
    Hecks::Runtime::Dispatcher.new(boot(carrier(adapter))).query("Courier::Parcel.Rates",
                                                                 destination: { value: destination })
  end

  def malformed(row)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "broken.adapter")
      File.write(path, "Hecks.adapter \"Broken\" do\n  port \"Carrier\"\n  #{row}\nend\n")
      Hecks.with_registry(Hecks::Runtime::Registry.new) { Kernel.load(path) }
    end
  end

  describe "answering an ask" do
    it "answers from the first row whose where holds, and the answer settles the parcel" do
      expect(booked("recorded", "Lisbon")).to eq(%w[ParcelBooked CarrierCollected ParcelSettled])
    end

    it "carries the declared answer into the domain" do
      expect(parcel("recorded", "Oslo")).to include(tracking: { value: "NO-0001" }, status: "collected")
    end

    it "copies the asked fields it is echoing into the answer" do
      expect(answered("echo", ref: { value: "P-7" }, destination: { value: "Lima" }))
        .to eq(tracking: { value: "echoed" }, ref: { value: "P-7" })
    end

    it "words a refusal its row declares as the port's refuses event" do
      refusal = parcel("echo", "Atlantis")[:refusal]
      expect(refusal).to eq(value: "#{Hecks::Runtime::DeclaredAdapter::Refused}: no road reaches Atlantis")
    end

    it "refuses an asking no row matches, naming the values it was asked" do
      refusal = parcel("recorded", "Paris")[:refusal][:value]
      expect(refusal).to end_with("RecordedCarrier has no reply for Collect where destination: \"Paris\"")
    end
  end

  describe "answering a query" do
    it "answers a list of rows, each built as the value object the query returns" do
      expect(rates("echo", "Lima")).to eq([{ service: "standard", cents: 500 }, { service: "express", cents: 1500 }])
    end

    it "refuses the query as the outside saying no" do
      expect { rates("recorded", "Atlantis") }.to raise_error(Hecks::Runtime::RemoteRefusal, /no road reaches Atlantis/)
    end
  end

  describe "swapping adapters by declaration" do
    it "boots the suite once per carrier beside it" do
      labels = Hecks::Behaviors::Expectations::AdapterSelection.variants(SUITE, [File.join(COURIER, "courier.bluebook")])
      expect(labels.map(&:first)).to eq(%w[EchoCarrier RecordedCarrier])
    end

    it "holds every carrier to the whole suite" do
      outcomes = Hecks::Behaviors.run(SUITE).runs.group_by(&:adapter).transform_values { |rows| rows.map(&:status).uniq }
      expect(outcomes).to eq("EchoCarrier" => [:pass], "RecordedCarrier" => [:pass])
    end

    it "keeps a declared carrier inside, so a suite may boot it" do
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) { Kernel.load(carrier("echo")) }
      expect(registry.adapters.values.first.stays_inside?).to be(true)
    end
  end

  describe "refusing a row that is not data" do
    it "refuses a float, naming why" do
      expect do
        malformed('replies "Collect", with: { cents: 1.5 }')
      end.to raise_error(Hecks::Bluebook::DSL::Malformed, /counts in integers/)
    end

    it "refuses code where data belongs" do
      expect do
        malformed('replies "Collect", with: { tracking: "x".upcase }')
      end.to raise_error(Hecks::Bluebook::DSL::Malformed, /not data/)
    end

    it "refuses a refusal that does not say why" do
      expect do
        malformed('refuses "Collect", where: { destination: "Oslo" }')
      end.to raise_error(Hecks::Bluebook::DSL::Malformed, /saying/)
    end
  end
end
