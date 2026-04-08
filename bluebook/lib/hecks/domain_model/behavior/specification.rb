module Hecks
  module BluebookModel
    module Behavior

    # Hecks::BluebookModel::Behavior::Specification
    #
    # Intermediate representation of a domain specification -- a named, reusable
    # predicate defined in the DSL. Each specification has a name and a block that
    # tests whether an object satisfies a business rule.
    #
    # Specifications are used in two contexts:
    # 1. Directly, to filter or validate domain objects (e.g. "is this loan high risk?")
    # 2. In workflows, as branch conditions that determine which execution path to take
    #
    # Part of the BluebookModel IR layer. Built by the DSL aggregate builder and
    # consumed by SpecificationGenerator to produce specification classes in the
    # domain gem. At runtime, the block is called with a domain object and returns
    # a boolean.
    #
    #   spec = Specification.new(name: "HighRisk", block: proc { |loan| loan.principal > 50_000 })
    #   spec.name   # => "HighRisk"
    #   spec.block  # => #<Proc>
    #
    class Specification
      # @return [String] PascalCase specification name (e.g. "HighRisk", "IsActive")
      # @return [Proc] predicate block that receives a domain object and returns
      #   true/false indicating whether the object satisfies this specification
      attr_reader :name, :block

      # Creates a new Specification IR node.
      #
      # @param name [String] PascalCase specification name (e.g. "HighRisk")
      # @param block [Proc] predicate callable that receives a domain object
      #   and returns truthy/falsy. Must accept exactly one argument.
      # @return [Specification]
      def initialize(name:, block:)
        @name = name
        @block = block
      end
    end
    end
  end
end
