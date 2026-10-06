module Hecks
  module Bluebook
    module DSL
      class CommandBuilder
        # Build-time resolution of the attributes a command's mutations imply: `sets :field` alone
        # imports the owner's attribute of that name, and a mutation source that names nothing
        # declared is refused.
        module ImplicitAttributes
          # For exactly these ops, a bare Symbol source has exactly one legitimate reading —
          # a declared argument's name — since `append`'s record-state fallback doesn't apply
          # here; anything else would resolve to nil forever, indistinguishable from an
          # absent optional argument, unless refused explicitly.
          CHECKED_SYMBOL_SOURCE_OPS = %i[set increment decrement multiply remove].freeze
          private_constant :CHECKED_SYMBOL_SOURCE_OPS

          private

          # `sets :field` alone already means the command accepts an argument named `:field` —
          # when the command hasn't declared its own `:field`, imports the owner's already-built
          # `Attribute` verbatim instead of requiring a redundant re-declaration (ADR 0025).
          # Requires the owner's own attributes to already exist by the time `build` runs.
          def resolve_implicit_attributes!
            import_implied_attributes!
            # A second, separate pass: every mutation's own self-referential import must land
            # before any source is checked against the final `attributes` list, or a legal
            # declaration order gets refused.
            refuse_unknown_argument_sources_everywhere!
          end

          def import_implied_attributes!
            @mutations.each do |mutation|
              case mutation.op
              when :set    then resolve_bare_set!(mutation)
              when :append then resolve_append_fields!(mutation)
              end
              refuse_unknown_state_sources!(mutation)
            end
          end

          def refuse_unknown_argument_sources_everywhere!
            @mutations.each { |mutation| refuse_unknown_argument_sources!(mutation) }
          end

          # The bare self-referential shape (`source == target`) is `resolve_bare_set!`'s
          # own territory — skipped here so an undeclared field is refused as a target
          # problem, not misreported as a source problem.
          def refuse_unknown_argument_sources!(mutation)
            return unless undeclared_argument_source?(mutation)

            raise Malformed,
                  "#{@name}'s sets :#{mutation.target} resolves :#{mutation.source} from its " \
                  "arguments, but #{@name} declares no #{mutation.source} attribute — an " \
                  "argument that does not exist resolves to nil, always, never what the " \
                  "caller actually sent"
          end

          def undeclared_argument_source?(mutation)
            CHECKED_SYMBOL_SOURCE_OPS.include?(mutation.op) && mutation.source.is_a?(Symbol) &&
              !bare_self_reference?(mutation) && attributes.none? { |attr| attr.name == mutation.source }
          end

          # `state(:name)` snapshots one of the owner's own fields; refused at build, the
          # same way an unknown `given` reference is.
          def refuse_unknown_state_sources!(mutation)
            sources = mutation.source.is_a?(Hash) ? mutation.source.values : [mutation.source]
            sources.grep(StateRef).each do |ref|
              next if @owner_attributes.any? { |attr| attr.name == ref.name }

              raise Malformed, "#{@name}'s sets :#{mutation.target} reads state(:#{ref.name}), " \
                               "which the owner does not declare"
            end
          end

          # Only a Symbol naming its own target qualifies — a literal that merely spells the
          # same word (`sets :moved, to: "moved"`) must not import a phantom argument.
          def bare_self_reference?(mutation)
            mutation.source.is_a?(Symbol) && mutation.source.to_s == mutation.target.to_s
          end

          def resolve_bare_set!(mutation)
            return unless bare_self_reference?(mutation)
            return if attributes.any? { |attr| attr.name == mutation.target }

            owner_attr = @owner_attributes.find { |attr| attr.name == mutation.target }
            attributes << owner_attr if owner_attr
          end

          # One hop deeper than `resolve_bare_set!`: an `append:` mutation builds a new list
          # element, so a bare self-referential field inside it resolves against the list's
          # own element type (`element_type_for`), not `@owner_attributes`.
          def resolve_append_fields!(mutation)
            element = element_type_for(mutation.target) if mutation.source.is_a?(Hash)
            return unless element

            fields = self_referential_fields(mutation.source)
            present = fields.filter_map { |field| attributes.find { |attr| attr.name == field } }
            # Already fully declared — nothing to resolve.
            reinsert_fields(fields, present, element) unless fields.empty? || present.size == fields.size
          end

          def self_referential_fields(source)
            source.select { |field, value| value.is_a?(Symbol) && value.to_s == field.to_s }.keys
          end

          # Position-preserving, not appended at the end — the exported IR is array-order-
          # sensitive, so resolved fields are reinserted at the position the group's leftmost
          # still-declared member already occupied.
          def reinsert_fields(fields, present, element)
            anchor = present.empty? ? attributes.length : present.map { |attr| attributes.index(attr) }.min
            attributes.reject! { |attr| present.include?(attr) }
            attributes.insert(anchor, *resolved_group(fields, present, element))
          end

          def resolved_group(fields, present, element)
            fields.filter_map do |field|
              present.find { |attr| attr.name == field } || element.attributes.find { |attr| attr.name == field }
            end
          end

          # The owner's own list attribute names its element type as text; resolved against
          # `@owner_constructs` (the only two kinds an element can be) by `hecks_name`.
          def element_type_for(list_field)
            list_attr = @owner_attributes.find { |attr| attr.name == list_field && attr.list? }
            return nil unless list_attr

            @owner_constructs.find { |construct| construct.hecks_name.to_s == list_attr.type.to_s }
          end
        end
      end
    end
  end
end
