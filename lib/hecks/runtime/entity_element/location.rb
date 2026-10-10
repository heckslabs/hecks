require_relative "../../naming"
require_relative "../refusal_wording"
require_relative "../errors"
require_relative "../identity"
require_relative "../value"

module Hecks
  module Runtime
    module EntityElement
      # Finds the one element a command addresses inside an aggregate record, hop by hop down
      # the entity chain. Extended onto {EntityElement}.
      module Location
        # One step down the chain: the owner holding the list, the entity whose elements it
        # holds, the container the list is read from, and how the element is named.
        Hop = Struct.new(:root_aggregate, :owner, :entity, :command_name, :container, :args, :routed_identity)

        # Walks `chain` one hop at a time and returns the located element (or `instance`
        # itself when `chain` is empty). `route`, when given, offers each hop's identity
        # before falling back to `args`.
        # rubocop:disable-next Metrics/ParameterLists -- the positional entry point EntityInterpreter and delegation call
        def locate_chain(root_aggregate, chain, instance, args, command_name, route = nil)
          container = instance
          owner     = root_aggregate
          chain.each_with_index do |entity, index|
            hop = Hop.new(root_aggregate, owner, entity, command_name, container, args, route&.entities&.fetch(index))
            container = element_of(hop)
            owner = entity
          end
          container
        end

        # An element's identity, joined from its declared identity paths (read off the
        # stored Hash, not a dispatch payload).
        def element_identity(entity, element)
          parts = entity.identity_paths.map do |path|
            head = path.to_s.split(".").first.to_sym
            Identity.scalar(path, element[head])
          end

          Naming.identity(parts)
        end

        private

        # Locates one element, matching every part of its declared identity, and copies
        # the owning list and the element before any write so nothing aliases the caller's
        # record. `routed_identity`, when given, matches directly by the element's own
        # identity string instead of re-deriving `wants` from `args`.
        def element_of(hop)
          list_attr = holding_list(hop.owner, hop.entity)
          wants     = identity_wants(hop) unless hop.routed_identity
          original  = Array(hop.container[list_attr.name])
          position  = element_position(hop, original, wants) || refuse_missing_element(hop, wants)
          copy_element(hop.container, list_attr, original, position)
        end

        # Copies the list and the found element before handing either back — the list
        # attribute holds Hashes, and the caller mutates the returned element in place,
        # so this keeps that mutation off the adapter's own record until it commits.
        def copy_element(container, list_attr, original, position)
          copied  = original.dup
          element = copied[position].dup
          copied[position] = element
          container[list_attr.name] = copied
          element
        end

        def holding_list(owner, entity)
          owner.attributes.find { |a| a.list? && a.type.to_s == entity.hecks_name } ||
            raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "entity_holds_no_list",
                                                          aggregate: owner.hecks_name, entity: entity.hecks_name))
        end

        # The `[head, path, wanted value, raw]` the dispatch's arguments name for each part of
        # the entity's identity.
        def identity_wants(hop)
          hop.entity.identity_paths.map do |path|
            head = path.to_s.split(".").first.to_sym
            raw  = hop.args[head] || refuse_no_identity(hop)

            [head, path, wanted_value(hop, head, raw), raw]
          end
        end

        def refuse_no_identity(hop)
          entity = hop.entity
          raise NotFound, RefusalWording.render_site("NotFound", "entity_element_no_identity",
                                                     command: hop.command_name, entity: entity.hecks_name,
                                                     identity: Identity.reading(entity))
        end

        # A value that fails its own type's invariant can never match a stored
        # element (every stored one already satisfies it) — degrade to
        # `UNMATCHABLE` here rather than letting InvariantViolation propagate.
        def wanted_value(hop, head, raw)
          Value.for_attribute(hop.root_aggregate, hop.entity.attribute(head), raw)
        rescue InvariantViolation
          UNMATCHABLE
        end

        def element_position(hop, original, wants)
          if hop.routed_identity
            original.find_index { |element| element_identity(hop.entity, element).to_s == hop.routed_identity.to_s }
          else
            original.find_index do |el|
              wants.all? { |head, _path, want, _raw| want != UNMATCHABLE && el[head] == want }
            end
          end
        end

        def refuse_missing_element(hop, wants)
          container = hop.container
          raise NotFound, RefusalWording.render_site(
            "NotFound", "entity_element_missing",
            entity: hop.entity.hecks_name, identity: Identity.reading(hop.entity),
            wants: wants&.map { |_h, path, _want, raw| Identity.scalar(path, raw) }&.join(", "),
            aggregate: hop.owner.hecks_name,
            parent_id: container.respond_to?(:id) ? container.id.inspect : Rendering.describe(container)
          )
        end
      end
    end
  end
end
