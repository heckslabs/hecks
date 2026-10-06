require_relative "bluebook"
require_relative "codemod"
require_relative "projections/model"
require_relative "fuzzing/properties"
require_relative "query_ir/rules"
require_relative "query_ir/formatting"
require_relative "query_ir/touchpoints"

module Hecks
  # Shared core of `hecks ir_constructs` and `hecks serve_query_ir_mcp`.
  # Returns structured data; formatting belongs to each front end.
  #
  # The rule collection, the text renderings and the propagation touchpoints live in `Rules`,
  # `Formatting` and `Touchpoints`, extended onto this module.
  module QueryIR
    Codemod    = Hecks::Codemod
    Deviations = Hecks::Projections::Model::Deviations

    # Mirrors the conformance spec's MODEL_CONSTRUCTS; kept here because a spec is not a library.
    CONSTRUCTS = {
      "Bluebook"       => Hecks::Bluebook::Chapter,
      "Aggregate"      => Hecks::Bluebook::Aggregate,
      "Command"        => Hecks::Bluebook::Command,
      "Entity"         => Hecks::Bluebook::Entity,
      "ValueObject"    => Hecks::Bluebook::ValueObject,
      "Policy"         => Hecks::Bluebook::Policy,
      "Query"          => Hecks::Bluebook::Query,
      "ReadModel"      => Hecks::Bluebook::ReadModel,
      "ProcessManager" => Hecks::Bluebook::ProcessManager
    }.freeze

    Rule = Struct.new(:kind, :description, :canonical, :location, keyword_init: true)

    extend Rules
    extend Formatting
    extend Touchpoints

    module_function

    # Reads the fields the language declares for one construct kind, from the grammar itself.
    #
    # @param name [String] a `CONSTRUCTS` key, such as `"Aggregate"`
    # @return [Array<Symbol>] the attribute names the self-hosted meta-domain
    #   grammar declares for `name`
    def meta_declared(name)
      Hecks::Bluebook::MetaValidator.grammar_registry
                                    .bluebook("Bluebook").aggregate(name).attributes.map(&:name)
    end

    # The structural diff between what a Ruby IR class emits (`ir_spec.keys`) and what the
    # self-hosted meta-domain declares, using the `Deviations` data the conformance spec reads.
    # @param name [String] a `CONSTRUCTS` key, such as `"Aggregate"`
    # @return [Hash{Symbol => Object}] `:name`, `:declared`, `:emitted`, plus
    #   `:missing_from_ruby` and `:unaccounted_in_ruby` — each an `Array<Symbol>`
    # @raise [ArgumentError] if `name` is not a `CONSTRUCTS` key
    def construct_diff(name)
      klass = CONSTRUCTS.fetch(name) do
        raise ArgumentError, "no such construct #{name.inspect} — known: #{CONSTRUCTS.keys.join(", ")}"
      end
      declared = meta_declared(name)
      emitted  = klass.ir_spec.keys

      { name: name, declared: declared, emitted: emitted,
        missing_from_ruby: accounted_fields(name, declared) - emitted,
        unaccounted_in_ruby: unaccounted_fields(name, declared, emitted) }
    end

    # @return [Array<Symbol>] the declared fields the Ruby class must emit: all but the named
    #   deviations
    def accounted_fields(name, declared)
      declared.reject { |field| Deviations.parent_ref?(field) } -
        Deviations.judge_only(name) -
        Deviations.folded(name).values.flatten -
        Deviations.off_the_wire(name) -
        Deviations.dynamic_tail(name) -
        Deviations.unpacked(name).keys
    end

    # @return [Array<Symbol>] the emitted fields the grammar does not declare and no deviation names
    def unaccounted_fields(name, declared, emitted)
      emitted -
        declared -
        Deviations.contained(name) -
        Deviations.folded(name).keys -
        Deviations.computed(name) -
        Deviations.unpacked(name).values.flatten
    end

    # Diffs one or every construct kind at once.
    #
    # @param names [Array<String>] `CONSTRUCTS` keys to diff, every construct when empty
    # @return [Array<Hash>] one `construct_diff` result per name
    def constructs(names = [])
      targets = names.empty? ? CONSTRUCTS.keys : names
      targets.map { |name| construct_diff(name) }
    end
  end
end
