require "spec_helper"

# The wiring checks that read only the declarations run once for a registry a process boots many
# times, and a read-only boot opens only the stores a line asks about (ADR 0201, "The warm path").
RSpec.describe Hecks::Runtime::Registry do
  let(:registry) { described_class.new }
  let(:checks) { described_class::DeclarationChecks::CHECKS }
  let(:declared) { registry.instance_variable_get(:@declared) }

  before { checks.each { |check| allow(registry).to receive(check) } }

  describe "#verify_declarations!" do
    it "runs the checks the first time" do
      registry.verify_declarations!
      expect(registry).to have_received(:refuse_unresolved_ports!).once
    end

    it "does not run them again for a registry that passed" do
      2.times { registry.verify_declarations! }
      expect(registry).to have_received(:refuse_unresolved_ports!).once
    end

    it "runs them again once something is declared" do
      registry.verify_declarations!
      declared.store(:bluebooks, "Pizzas", Object.new)
      registry.verify_declarations!
      expect(registry).to have_received(:refuse_unresolved_ports!).twice
    end

    it "remembers only a pass, so a failure raises each time" do
      allow(registry).to receive(:verify_world_defaults!).and_raise(Hecks::Runtime::WiringError, "no")
      2.times { expect { registry.verify_declarations! }.to raise_error(Hecks::Runtime::WiringError) }
    end

    it "keeps the order the checks have always run in" do
      expect(checks.first(3)).to eq(%i[verify_default_adapter! verify_world_defaults! verify_singleton_port_answers!])
    end
  end

  describe "a declaration changing" do
    it "forgets a pass when a keyed value is stored" do
      declared.verified = true
      declared.store(:worlds, "W", Object.new)
      expect(declared.verified).to be(false)
    end

    it "forgets a pass when a key is removed" do
      declared.verified = true
      declared.remove(:worlds, "W")
      expect(declared.verified).to be(false)
    end

    it "forgets a pass when a value is appended" do
      declared.verified = true
      declared.append(:translations, 1)
      expect(declared.verified).to be(false)
    end

    it "forgets a pass when a source is recorded" do
      declared.verified = true
      declared.record_source("B", "b.bluebook")
      expect(declared.verified).to be(false)
    end
  end

  describe "#verify_bind!" do
    let(:hecksagon) { instance_double(Hecks::Bluebook::Hecksagon, domain: "Pizzas") }
    let(:bind) { instance_double(Hecks::Bluebook::Bind, aggregate: "Pizza", aggregate_name: "Pizza") }

    before { allow(registry).to receive_messages(bluebook: double(aggregate: :pizza), check_verb: nil, repository: nil) }

    it "opens the store of a bound aggregate for a boot that acts" do
      registry.send(:verify_bind!, hecksagon, bind)
      expect(registry).to have_received(:repository).with("Pizzas", :pizza)
    end

    it "opens no store for a read-only boot" do
      registry.send(:verify_bind!, hecksagon, bind, open_stores: false)
      expect(registry).not_to have_received(:repository)
    end

    it "still checks the bind's adapter for a read-only boot" do
      registry.send(:verify_bind!, hecksagon, bind, open_stores: false)
      expect(registry).to have_received(:check_verb).with(bind)
    end
  end

  describe "#verify!" do
    before { allow(registry).to receive_messages(refuse_forgetful_sagas!: nil, verify_hecksagons!: nil) }

    it "checks the sagas' checkpoints for a boot that acts" do
      registry.verify!
      expect(registry).to have_received(:refuse_forgetful_sagas!)
    end

    it "leaves the sagas' checkpoints for a read-only boot" do
      registry.verify!(open_stores: false)
      expect(registry).not_to have_received(:refuse_forgetful_sagas!)
    end

    it "passes the choice on to the hecksagons' checks" do
      registry.verify!(open_stores: false)
      expect(registry).to have_received(:verify_hecksagons!).with(open_stores: false)
    end
  end
end
