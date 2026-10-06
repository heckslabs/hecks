require "spec_helper"
require "hecks/bluebook/synthesizer"
require "tmpdir"
require_relative "../support/memory_ports"

RSpec.describe Hecks::Bluebook::Synthesizer do
  # Real IR from pizzas.bluebook: a closed set (`Size`), a multi-field value object (`Topping`),
  # and a value object nested in another (`Pizza.price_cents: Price`).
  let(:chapter) do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
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

    it "gives a boolean type false", :aggregate_failures do
      expect(described_class.scalar_for("TrueClass")).to be(false)
      expect(described_class.scalar_for("FalseClass")).to be(false)
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

    # Regression: `Pizza.price_cents` is a nested value object, not a primitive, and must not
    # collapse to a marker string.
    it "recurses into a nested value object rather than treating it as an opaque scalar" do
      value = described_class.value_for(chapter, order, "Pizza")

      expect(value).to eq({ price_cents: { cents: 0 }, size: { value: "small" } })
    end

    it "falls back to a marker string for a type name declared nowhere in the chapter" do
      expect(described_class.value_for(chapter, order, "NoSuchType")).to eq("smoke-test")
    end
  end

  describe ".args_for" do
    # A bare self-reference is never a declared attribute (`SmokeTest` supplies it via `id:`),
    # so cross-aggregate references are tested against a small hand-built domain.
    around do |example|
      @root = Dir.mktmpdir("hecks-synth-")
      example.run
    ensure
      FileUtils.remove_entry(@root) if @root
    end

    WIDGET_SOURCE = <<~RUBY.freeze
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

    it "synthesizes every declared argument for a real command, respecting each field's own type, nested or not" do
      args = described_class.args_for(chapter, order, order.command("CreatePizza"))

      expect(args).to eq(name: { value: "smoke-test" }, pizza: { price_cents: { cents: 0 }, size: { value: "small" } })
    end

    # Writes the hand-built domain to the scratch directory and returns its bluebook's path.
    def write_widget_bluebook
      directory = File.join(@root, "widget", "bluebook")
      FileUtils.mkdir_p(directory)
      File.join(directory, "widget.bluebook").tap { |path| File.write(path, WIDGET_SOURCE) }
    end

    def referencing_command
      path = write_widget_bluebook
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        MemoryPorts.load!
        Kernel.load(path)
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
