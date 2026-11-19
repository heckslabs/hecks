# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/dispatching"
require "hecks/hecks/adapters/machine_sampling"

# The `metering.roundhouse` switch (ADR 0222, phase 3, metering): off, Delegate reads its load from
# `uptime`; on, from Roundhouse's meter. Every outside read is a stand-in here.
RSpec.describe Hecks::Adapters::Dispatching::MeterSwitch do
  let(:switch) { described_class }

  def registry(roundhouse)
    settings = roundhouse.nil? ? {} : { "metering" => { roundhouse: roundhouse } }
    world = Hecks::Bluebook::World.new(domain: "Tickets", settings: settings)
    instance_double(Hecks::Runtime::Registry, world: world, bluebook: nil)
  end

  def meter(hundredths) = instance_double(Hecks::Adapters::Metering, load_facts: { load: hundredths, cores: 6 })

  it "is off when the world names no switch, and with no registry", :aggregate_failures do
    expect(switch.on?(registry(nil))).to be(false)
    expect(switch.on?(nil)).to be(false)
  end

  it "is on only when the world turns it on", :aggregate_failures do
    expect(switch.on?(registry(true))).to be(true)
    expect(switch.on?(registry(false))).to be(false)
  end

  it "reads the meter's load in hundredths as a load average" do
    expect(switch.load(meter(702))).to eq(7.02)
  end

  it "answers no load when the meter could not read one, never a calm 0" do
    expect(switch.load(meter(nil))).to be_nil
  end

  describe "the fill's load" do
    let(:settings_class) { Hecks::Adapters::Dispatching::Settings }

    before { allow(settings_class).to receive(:uptime_load).and_return(9.0) }

    it "reads uptime while the switch is off", :aggregate_failures do
      settings = settings_class.new(registry(false))

      expect(settings.load).to eq(9.0)
      expect(settings.load_source).to eq("uptime")
    end

    it "reads Roundhouse's meter once the switch is on", :aggregate_failures do
      allow(switch).to receive(:load).and_return(7.02)
      settings = settings_class.new(registry(true))

      expect(settings.load).to eq(7.02)
      expect(settings.load_source).to eq("roundhouse")
    end

    it "falls back to uptime when the meter could not read", :aggregate_failures do
      allow(switch).to receive(:load).and_return(nil)
      settings = settings_class.new(registry(true))

      expect(settings.load).to eq(9.0)
      expect(settings.load_source).to eq("uptime")
    end
  end

  describe "the Machine reading" do
    let(:gauges) { { cpu_idle: 50.0, load: 9.0, free_gb: 10.0, swap_used_mb: 0.0, compressor_gb: 1.0 } }

    def read(roundhouse, metered = 7.02)
      Hecks::Adapters::MachineSampling.last = nil
      settings = { readings: -> { gauges }, clock: -> { 1.0 }, meter: -> { metered } }
      Hecks::Adapters::MachineSampling.new(registry: registry(roundhouse), settings: settings).read
    end

    it "keeps the metered load beside uptime's while the switch is off" do
      expect(read(false)).to include(load: 9.0, metered_load: 7.02, source: "uptime")
    end

    it "counts the metered load once the switch is on" do
      expect(read(true)).to include(load: 7.02, metered_load: 7.02, source: "roundhouse")
    end

    it "keeps uptime's load when the meter could not read" do
      expect(read(true, nil)).to include(load: 9.0, metered_load: nil, source: "uptime")
    end
  end
end
