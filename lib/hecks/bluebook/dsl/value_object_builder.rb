require_relative "word_gate"
module Hecks
  module Bluebook
    module DSL
      # Parses a `value_object "Name" do ... end` block into a `ValueObject`: its attributes,
      # invariants and, for a closed set, its `member` rows.
      class ValueObjectBuilder
        GRAMMAR_CONTEXT = "ValueObject".freeze

        include AttributeCollector
        include RuleReference
        include WordGate

        # @param name [String] the value object's name, as written after `value_object`
        # @param owner_value_objects [Array<Bluebook::ValueObject>] the owning aggregate's other
        #   value objects, built so far, that this one's `invariant` references may resolve
        #   against
        def initialize(name, owner_value_objects: [])
          @name       = name
          @invariants = []
          @members    = []
          @owner_value_objects = owner_value_objects
        end

        # Bare values declare a closed set; the block form is read only under shadow-parsing,
        # because frozen era text still writes it. Only the wrapper passes a block.
        def one_of_impl(*values, &block)
          unless block
            # An empty one_of names a closed set with nothing in it; refuse rather than no-op.
            if values.empty?
              raise Malformed,
                    "#{@name}'s one_of names no values — one_of(\"a\", \"b\") takes at least one, or " \
                    "give the attribute its own one_of: [...] for a named closed set"
            end

            return super(*values)
          end

          unless MetaValidator.shadow_parsing?
            raise Malformed,
                  "#{@name}'s one_of do ... end wrapper is gone — give the single attribute its " \
                  "own one_of: [...], or write bare member lines with no wrapper for a multi-field set"
          end

          @closed_set = true
          instance_eval(&block)
        end

        def member_impl(**fields)
          raise Malformed, "#{@name} declared an empty member" if fields.empty?

          @members << fields
        end

        # Without a block this references a rule a sibling value object already declared.
        # Resolution runs at build time, so declare the rule before its referrers.
        def invariant_impl(description, &predicate)
          return reference_named_invariant(description) unless predicate

          @invariants << build_rule(Invariant, description, predicate, owner_name: @name, word: "invariant",
                                     extraction_failure: "it would be a rule the IR cannot carry")
        end

        private

        # A live scan of the siblings built so far, not a pool (see RuleReference).
        def reference_named_invariant(description)
          verify_resolves_via!("invariant", "ValueObject", "sibling_scan")
          named = resolve_sibling_scan(@owner_value_objects, description, reader: :invariants) ||
                  raise(Malformed,
                        "#{@name}'s invariant #{description.inspect} names no rule a sibling value " \
                        "object on this aggregate declares — declare it once with a block, on the " \
                        "value object that needs it first, before the ones that reference it back")

          @invariants << named
        end

        public

        def build
          if @inline_closed_set_field && attributes.size > 1
            raise Malformed,
                  "#{@name}'s one_of: on :#{@inline_closed_set_field} only works when it is the " \
                  "value object's only attribute — #{attributes.size} declared here; write bare " \
                  "member lines instead for a multi-field set"
          end

          ValueObject.declare(
            name: @name, attributes: attributes,
            invariants: @invariants, members: @members,
            closed_set: @closed_set || !@members.empty?
          )
        end

        def self.build(name, owner_value_objects: [], &block)
          builder = new(name, owner_value_objects: owner_value_objects)
          builder.instance_eval(&block) if block
          builder.build
        end

        private

        # Private callback `attribute` invokes for `one_of:`. A single-field set names exactly one
        # field; a second one would leave it ambiguous which field each member line belongs to.
        def install_inline_closed_set(field, values)
          if @inline_closed_set_field && @inline_closed_set_field != field
            raise Malformed,
                  "#{@name} declares one_of: on more than one attribute (:#{@inline_closed_set_field} " \
                  "and :#{field}) — a single-field closed set names exactly one"
          end

          @inline_closed_set_field = field
          @closed_set = true
          values.each { |value| member_impl(field => value.to_s) }
        end
      end
    end
  end
end
