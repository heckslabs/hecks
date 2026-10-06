module Hecks
  module Bluebook
    module MetaValidator
      class Judge
        # How the judge names and addresses what it offers: record ids, dotted verb paths, and
        # the wrapping of a value as the one-field value object the language expects.
        module Identity
          private

          # nil stays nil so an optional field reads as undeclared rather
          # than declared-empty; an Integer passes through raw so a typed
          # field (RowCount's `value`) still hits its own type gate.
          def v(text)
            return nil if text.nil?
            return { value: text } if text.is_a?(Integer)

            { value: text.to_s }
          end

          # A reference argument is passed as the bare id it names; every
          # other field is wrapped as a one-field value object instead.
          def carried(plan, verb, argument, value)
            return v(value) unless plan && verb && plan.references?(verb, argument)

            value
          end

          # A record's id is its declared identity, joined the same way the
          # runtime joins it, so there is exactly one way to name a thing.
          # Each part comes from the parent link, the walk index
          # (`position`), or a field read off the node.
          def identify(visit)
            plan = @plan.category(visit.category)
            return declared_name(visit.node) unless plan

            Naming.identity(plan.identity_paths.map { |path| identity_part(plan, path, visit) })
          end

          def identity_part(plan, path, visit)
            head = path.to_s.split(".").first
            return visit.parent_id.to_s if head == plan.parent_key.to_s || head == OWNER
            return visit.index.to_s     if head == POSITION

            v_scalar(field_value(visit.category, visit.node, head.to_sym, visit.parent_id))
          end

          # The scalar inside whatever the reading handed back: a name is
          # already one, a value object is not.
          def v_scalar(held)
            return held.to_s unless held.respond_to?(:to_h) && !held.is_a?(String)

            held.to_h.values.first.to_s
          end

          # Each identity field comes from one of three places: the parent
          # link, the walk's own index (`POSITION`), or a real field read off
          # the node.
          def node_identity(plan, visit)
            plan.identity_paths.each_with_object({}) do |path, fields|
              head = path.to_s.split(".").first
              next if head == OWNER

              fields[head.to_sym] = identity_field(plan, head, visit)
            end
          end

          def identity_field(plan, head, visit)
            return v(visit.index) if head == POSITION

            carried(plan, plan.declare, head, identity_source(plan, head, visit))
          end

          # The raw value an identity head reads from: the parent link, or a field of the node.
          def identity_source(plan, head, visit)
            return visit.parent_id if head == plan.parent_key.to_s

            field_value(visit.category, visit.node, head.to_sym, visit.parent_id)
          end

          # An ordinary category's own top-level aggregate reaches every
          # verb bare; an entity-owned one prefixes its parent's own dotted
          # path instead (ADR 0026), since a nested entity's parent may
          # itself be entity-owned.
          def dotted_prefix(plan)
            return plan.name unless plan.entity_owned

            "#{dotted_prefix(@plan.category(plan.parent))}.#{plan.name}"
          end

          # Entity-owned categories have no top-level aggregate to route a
          # bare verb into, so the verb is addressed by this category's
          # full dotted path instead.
          def verb_for(plan, verb)
            "#{dotted_prefix(plan)}.#{verb}"
          end

          # A bare id when there is no entity hop (the common case); the
          # full {aggregate:, entities:} envelope only when there is one.
          def address(receiver)
            return receiver[:aggregate] if receiver[:entities].empty?

            receiver
          end
        end
      end
    end
  end
end
