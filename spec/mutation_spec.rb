require "spec_helper"

# A `sets` must name a field its aggregate declares; the build refuses one that does not.
RSpec.describe "sets" do
  VOID_BLUEBOOK = proc do
    vision "An aggregate whose command sets a field it never declared."
    supporting

    aggregate "Widget" do
      description "A widget with exactly one declared field."

      attribute :label, Label

      value_object "Label" do
        attribute :value, String

        invariant("a widget is labelled") { !value.to_s.empty? }
      end

      command "Make" do
        role "Maker"
        goal "Bring a widget into being"

        attribute :label, Label

        emits "WidgetMade"
      end

      command "Rename" do
        role "Maker"
        goal "Set a field the aggregate never declared"

        reference_to Widget
        attribute :nickname, Label

        # :nickname is not an attribute of Widget — :label is the only one.
        sets :nickname

        emits "WidgetRenamed"
      end
    end
  end

  # The language only requires a mutation target to be non-empty, so a sets naming an
  # undeclared field is well formed yet writes into nothing at runtime.
  describe "a mutation into a void" do
    def in_registry
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        yield
      end
      registry
    end

    def build_void_target = in_registry { Hecks.bluebook("Void", &VOID_BLUEBOOK) }

    it "refuses a sets naming a field the aggregate never declared" do
      expect { build_void_target }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /nickname/)
    end
  end
end
