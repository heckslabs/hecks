require "spec_helper"
require "tmpdir"

RSpec.describe Hecks::Configuration do
  def build_and_load(domain, _tmpdir = nil)
    Hecks.load(domain)
  end

  describe "multi-domain with shared event bus" do
    it "events from one domain are visible to all apps" do
      domain_a = Hecks.domain("DomainA") { aggregate("Thing") { attribute :name, String; command("CreateThing") { attribute :name, String } } }
      domain_b = Hecks.domain("DomainB") { aggregate("Other") { attribute :name, String; command("CreateOther") { attribute :name, String } } }

      tmpdir = Dir.mktmpdir("hecks_config_test")
      build_and_load(domain_a, tmpdir)
      build_and_load(domain_b, tmpdir)

      shared_bus = Hecks::EventBus.new
      app_a = Hecks.load(domain_a, event_bus: shared_bus)
      app_b = Hecks.load(domain_b, event_bus: shared_bus)

      DomainADomain::Thing.create(name: "test")

      expect(shared_bus.events.size).to eq(1)
      expect(shared_bus.events.first.class.name).to include("CreatedThing")
      expect(app_a.events.size).to eq(1)
      expect(app_b.events.size).to eq(1)
    end

    it "domains are isolated — can't access each other's classes" do
      domain_a = Hecks.domain("IsoA") { aggregate("Foo") { attribute :name, String; command("CreateFoo") { attribute :name, String } } }
      domain_b = Hecks.domain("IsoB") { aggregate("Bar") { attribute :name, String; command("CreateBar") { attribute :name, String } } }

      tmpdir = Dir.mktmpdir("hecks_iso_test")
      build_and_load(domain_a, tmpdir)
      build_and_load(domain_b, tmpdir)

      shared_bus = Hecks::EventBus.new
      Hecks.load(domain_a, event_bus: shared_bus)
      Hecks.load(domain_b, event_bus: shared_bus)

      expect(defined?(IsoADomain::Bar)).to be_nil
      expect(defined?(IsoBDomain::Foo)).to be_nil
    end
  end

  describe "Application with external event_bus" do
    it "uses the provided event bus instead of creating one" do
      domain = Hecks.domain("Ext") { aggregate("Widget") { attribute :name, String; command("CreateWidget") { attribute :name, String } } }
      tmpdir = Dir.mktmpdir("hecks_ext_bus_test")
      build_and_load(domain, tmpdir)

      custom_bus = Hecks::EventBus.new
      app = Hecks.load(domain, event_bus: custom_bus)

      expect(app.event_bus).to equal(custom_bus)

      ExtDomain::Widget.create(name: "test")
      expect(custom_bus.events.size).to eq(1)
    end
  end

  describe "chapter alias for domain" do
    it "chapter registers a domain entry the same as domain" do
      config = Hecks::Configuration.new
      config.chapter("pizzas_domain")
      expect(config.instance_variable_get(:@domains).size).to eq(1)
      expect(config.instance_variable_get(:@domains).first[:gem_name]).to eq("pizzas_domain")
    end
  end

  describe "gems DSL — extension gem loading" do
    let(:config) { Hecks::Configuration.new }
    let(:loaded) { [] }

    before do
      require "hecks/runtime/load_extensions"
      allow(Hecks::LoadExtensions).to receive(:require_one) { |name| loaded << name }
    end

    it "gems only: loads exactly the specified gems" do
      config.gems(only: [:audit, :logging])
      config.send(:require_extensions)

      expect(loaded).to contain_exactly(:audit, :logging)
    end

    it "gems except: skips excluded gems and loads the rest of AUTO" do
      config.gems(except: [:pii])
      config.send(:require_extensions)

      expect(loaded).not_to include(:pii)
      expect(loaded).to include(*Hecks::LoadExtensions::AUTO - [:pii])
    end

    it "default behavior loads the full AUTO list when no gems call is made" do
      allow(Hecks::LoadExtensions).to receive(:require_auto)
      config.send(:require_extensions)

      expect(Hecks::LoadExtensions).to have_received(:require_auto).once
    end

    it "boot! is idempotent — calling require_extensions twice does not double-load" do
      config.gems(only: [:audit])
      config.send(:require_extensions)
      config.send(:require_extensions)

      expect(loaded).to eq([:audit])
    end
  end
end
