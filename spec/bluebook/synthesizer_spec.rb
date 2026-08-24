require "spec_helper"
require "hecks/bluebook/synthesizer"
require "tmpdir"

RSpec.describe Hecks::Bluebook::Synthesizer do
  # A REAL, LOADED CHAPTER — the whole point of testing this against
  # actual IR rather than a hand-built double: `pizzas.bluebook`
  # already exercises a closed set (`Size`), a plain multi-field value
  # object (`Topping`), and — the case that first exposed a real gap
  # here — a value object whose OWN field is ANOTHER value object
  # (`Pizza.price_cents: Price`, not a raw primitive).
  let(:chapter) do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(InMemoryDomain::PIZZAS_BLUEBOOK)
    end
    registry.bluebook("Pizzas")
  end
  let(:order) { chapter.aggregate("Order") }

  describe ".scalar_for" do
    it "gives Integer a real Integer" do
      expect(described_class.scalar_for("Integer")).to eq(0)
    end

    it "gives Float a real Float" do
      expect(described_class.scalar_for("Float")).to eq(0.0)
    end

    it "gives a boolean type false" do
      expect(described_class.scalar_for("TrueClass")).to eq(false)
      expect(described_class.scalar_for("FalseClass")).to eq(false)
    end

    it "gives anything else a marker string" do
      expect(described_class.scalar_for("String")).to eq("smoke-test")
    end
  end

  describe ".value_for" do
    it "uses a closed set's own first admitted member, never an arbitrary string" do
      value = described_class.value_for(chapter, order, "Size")

      expect(value).to eq({ value: "small" })
    end

    it "synthesizes one scalar per declared field for a plain (non-closed) value object" do
      value = described_class.value_for(chapter, order, "Topping")

      expect(value).to eq({ name: "smoke-test", amount: 0 })
    end

    # THE BUG THIS ONCE HAD: `Pizza.price_cents` is typed `Price`, not
    # `Integer` — another value object, nested. A first version treated
    # anything non-primitive as an opaque marker string, so this came
    # back as `{price_cents: "smoke-test", size: "smoke-test"}` instead
    # of the real nested shape a command actually declares.
    it "recurses into a nested value object rather than treating it as an opaque scalar" do
      value = described_class.value_for(chapter, order, "Pizza")

      expect(value).to eq({ price_cents: { cents: 0 }, size: { value: "small" } })
    end

    it "falls back to a marker string for a type name declared nowhere in the chapter" do
      expect(described_class.value_for(chapter, order, "NoSuchType")).to eq("smoke-test")
    end
  end

  describe ".args_for" do
    it "synthesizes every declared argument for a real command, respecting each field's own type, nested or not" do
      command = order.command("CreatePizza")

      args = described_class.args_for(chapter, order, command)

      expect(args).to eq(
        name:  { value: "smoke-test" },
        pizza: { price_cents: { cents: 0 }, size: { value: "small" } }
      )
    end

    # `AddTopping` addresses Order by a bare self-reference (no `as:`),
    # which never becomes a declared attribute at all — the caller
    # (`SmokeTest`) supplies that separately via `id:`. What `args_for`
    # DOES own is a real CROSS-aggregate reference, tested here against
    # a small hand-built domain for full certainty about the shape.
    around do |example|
      @root = Dir.mktmpdir("hecks-synth-")
      example.run
    ensure
      FileUtils.remove_entry(@root) if @root
    end

    def referencing_command
      directory = File.join(@root, "widget", "bluebook")
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "widget.bluebook"), <<~RUBY)
        Hecks.bluebook "Widget" do
          aggregate "Item" do
            identified_by :name
            attribute :name, Name
            value_object "Name" do
              attribute :value, String
            end
            command "Add" do
              attribute :name, Name
            end
          end

          aggregate "Tag" do
            reference_to Item

            identified_by :item
            command "Attach" do
              reference_to Item
            end
          end
        end
      RUBY

      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.load(File.join(directory, "widget.bluebook"))
      end
      widget = registry.bluebook("Widget")
      [widget, widget.aggregate("Tag")]
    end

    it "reuses an already-created id for a reference argument instead of guessing" do
      chapter, tag = referencing_command

      args = described_class.args_for(chapter, tag, tag.command("Attach"), { "Item" => "headlamp" })

      expect(args[:item]).to eq("headlamp")
    end

    it "falls back to a placeholder id when the referenced target was never created" do
      chapter, tag = referencing_command

      args = described_class.args_for(chapter, tag, tag.command("Attach"), {})

      expect(args[:item]).to eq("smoke-test-id")
    end
  end
end
