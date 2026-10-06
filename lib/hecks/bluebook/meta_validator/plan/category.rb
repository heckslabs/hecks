module Hecks
  module Bluebook
    module MetaValidator
      class Plan
        # One append command: the verb, and the value-object-field -> argument map.
        # `:map` shadows Enumerable#map on purpose; spec/plan_spec.rb asserts on it.
        # rubocop:disable-next Lint/StructNewOverride
        Append = Struct.new(:verb, :map, keyword_init: true)

        # One setting command. `targets` is target -> argument ; Lifecycle sets two
        # fields in a single command, so it is a map rather than a pair.
        Setter = Struct.new(:verb, :targets, keyword_init: true)

        Category = Struct.new(:name, :declare, :parent, :parent_key, :fields,
                              :appends, :alternates, :setters, :sealers, :references,
                              :identity_paths, :entity_owned,
                              keyword_init: true) do
          # Every verb this category declares, in declaration order; a verb missing
          # here is one the coverage gate stops watching.
          #
          # @return [Array<String>] every command name this category declares
          #   (the creating command, every setter, appender, alternate
          #   appender, and sealer), `nil` entries dropped
          def verbs
            [declare, *setters.map(&:verb), *appends.values.map(&:verb),
             *alternates.map(&:verb), *sealers].compact
          end

          # Whether `argument` on `verb` carries an ID rather than a value.
          #
          # @param verb [String] the command name declaring `argument`
          # @param argument [String] the argument name to check
          # @return [Boolean] whether `argument` on `verb` is a reference
          def references?(verb, argument)
            Array(references[verb.to_s]).include?(argument.to_s)
          end

          # Whether this category has no parent — the root of the containment tree.
          def root? = parent.nil?
        end
      end
    end
  end
end
