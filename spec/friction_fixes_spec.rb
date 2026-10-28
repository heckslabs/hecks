require "spec_helper"

# Four edges a person wiring a domain meets first: a reaction that did not take is said aloud, a
# bulk form called without a query says what it is, an adapter can be told its context, and a
# sentence-form bluebook loads through the same door as a Ruby one.
RSpec.describe "friction at the edges" do
  describe "a reaction the domain refused" do
    let(:registry) { instance_double(Hecks::Runtime::Registry, reaction_event: nil) }
    let(:dispatcher) do
      Hecks::Runtime::Dispatcher.allocate.tap { |dispatcher| dispatcher.instance_variable_set(:@registry, registry) }
    end
    let(:refused) do
      [{ policy: "CompleteTheOrder", on: "OrderPaid", trigger: "Shop::Order.Complete",
         delivered: false, reason: "Order is not paid" }]
    end

    it "is warned to the caller, not only logged" do
      expect { dispatcher.send(:warn_blocked, refused) }
        .to output(/reaction CompleteTheOrder was refused \(Shop::Order\.Complete\): Order is not paid/).to_stderr
    end

    it "stays quiet for a reaction that delivered" do
      expect { dispatcher.send(:warn_blocked, [refused.first.merge(delivered: true)]) }.not_to output.to_stderr
    end

    it "leaves a nested reaction's refusal to the dispatch that started the cascade" do
      Thread.current[:hecks_reaction_depth] = 1
      expect { dispatcher.send(:warn_blocked, refused) }.not_to output.to_stderr
    ensure
      Thread.current[:hecks_reaction_depth] = 0
    end
  end

  describe "a bulk form called without a query" do
    let(:command) { Struct.new(:hecks_name).new("Complete") }

    it "says it is the bulk form and where the one-record form is" do
      expect { Hecks::Adapters::Driving::Ruby::BulkVerbs.refuse_unaimed!(command, nil) }
        .to raise_error(ArgumentError, /bulk form and needs over: a query.*one record.*handle/m)
    end

    it "lets a call with a query through" do
      expect(Hecks::Adapters::Driving::Ruby::BulkVerbs.refuse_unaimed!(command, Object.new)).to be_nil
    end
  end

  describe "an adapter that names its context" do
    let(:registry) { Object.new }
    let(:aggregate) { Object.new }
    let(:lookup) { Hecks::Runtime::AdapterLookup }

    let(:context_taker) do
      Class.new do
        attr_reader :registry, :aggregate

        def initialize(registry:, aggregate:)
          @registry = registry
          @aggregate = aggregate
        end
      end
    end

    it "is handed the registry and the aggregate it declares" do
      built = lookup.build(context_taker, registry: registry, aggregate: aggregate)

      expect([built.registry, built.aggregate]).to eq([registry, aggregate])
    end

    it "is handed only what it names" do
      klass = Class.new do
        attr_reader :registry

        def initialize(registry: nil) = @registry = registry
      end

      expect(lookup.build(klass, registry: registry, aggregate: aggregate).registry).to equal(registry)
    end

    it "is still built bare when it names nothing" do
      expect(lookup.build(Class.new, registry: registry, aggregate: aggregate)).to be_a(Object)
    end

    it "is accepted at boot when its constructor requires only the context" do
      klass = Class.new { def initialize(registry:) = @registry = registry }

      expect { lookup.check_buildable!(klass, "mail") }.not_to raise_error
    end

    it "is refused at boot when its constructor requires anything else" do
      klass = Class.new { def initialize(token:) = @token = token }

      expect { lookup.check_buildable!(klass, "mail") }
        .to raise_error(Hecks::Runtime::WiringError, /requires token/)
    end
  end

  describe "a sentence-form bluebook" do
    # A bluebook file whose first line is `first_line`, loaded through the one door.
    def load_through_door(first_line)
      file = Tempfile.new(["chapter", ".bluebook"])
      file.write("#{first_line}\n")
      file.flush
      yield file.path
    ensure
      file&.close!
    end

    it "is loaded by the same door as a Ruby one" do
      allow(Kernel).to receive(:load)

      load_through_door("Hecks.bluebook \"Shop\" do\nend") do |path|
        Hecks::SentenceForm.load_file(path)
        expect(Kernel).to have_received(:load).with(path)
      end
    end

    it "goes through the parser when its first line is a Domain line" do
      allow(Hecks::SentenceForm).to receive(:load)

      load_through_door("Domain: Shop") do |path|
        Hecks::SentenceForm.load_file(path)
        expect(Hecks::SentenceForm).to have_received(:load).with(path)
      end
    end
  end
end
