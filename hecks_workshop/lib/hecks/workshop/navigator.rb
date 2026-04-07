# Hecks::Workshop::Navigator
#
# Traverses a domain IR structure and yields each element with its depth
# and path context. Used by deep_inspect and any feature that needs to
# walk the full aggregate tree (value objects, entities, commands, events,
# policies, queries, scopes, specifications, subscribers, references).
#
#   navigator = Navigator.new(domain)
#   navigator.walk("Pizza") { |element, depth, label| ... }
#   navigator.walk_all { |element, depth, label| ... }
#
module Hecks
  class Workshop
    # Hecks::Workshop::Navigator
    #
    # Traverses a domain IR structure and yields each element with its depth
    # and path context. Used by DeepInspect to walk the full aggregate tree.
    #
    class Navigator
      # @param domain [DomainModel::Structure::Domain]
      def initialize(domain)
        @domain = domain
      end

      # Walk a single aggregate, yielding each structural element.
      #
      # @param aggregate_name [String] the aggregate to traverse
      # @yield [element, depth, label] called for each node in the tree
      # @yieldparam element [Object] the IR structure node
      # @yieldparam depth [Integer] nesting level (0 = aggregate root)
      # @yieldparam label [String] human-readable label for the node
      # @return [void]
      def walk(aggregate_name, &block)
        agg = @domain.aggregates.find { |aggregate| aggregate.name == aggregate_name }
        return unless agg

        walk_aggregate(agg, &block)
      end

      # Walk all aggregates in the domain.
      #
      # @yield [element, depth, label] called for each node
      # @return [void]
      def walk_all(&block)
        @domain.aggregates.each { |agg| walk_aggregate(agg, &block) }
      end

      private

      def walk_aggregate(agg, &block)
        yield agg, 0, "aggregate"
        walk_attributes(agg, 1, &block)
        walk_value_objects(agg, 1, &block)
        walk_entities(agg, 1, &block)
        walk_lifecycle(agg, 1, &block)
        walk_commands(agg, 1, &block)
        walk_events(agg, 1, &block)
        walk_queries(agg, 1, &block)
        walk_validations(agg, 1, &block)
        walk_invariants(agg, 1, &block)
        walk_policies(agg, 1, &block)
        walk_scopes(agg, 1, &block)
        walk_specifications(agg, 1, &block)
        walk_subscribers(agg, 1, &block)
        walk_references(agg, 1, &block)
      end

      def walk_attributes(agg, depth, &block)
        agg.attributes.each { |attr| yield attr, depth, "attribute" }
      end

      def walk_value_objects(agg, depth, &block)
        agg.value_objects.each do |vo|
          yield vo, depth, "value_object"
          vo.attributes.each { |attr| yield attr, depth + 1, "attribute" }
          vo.invariants.each { |inv| yield inv, depth + 1, "invariant" }
        end
      end

      def walk_entities(agg, depth, &block)
        agg.entities.each do |ent|
          yield ent, depth, "entity"
          ent.attributes.each { |attr| yield attr, depth + 1, "attribute" }
          ent.invariants.each { |inv| yield inv, depth + 1, "invariant" }
        end
      end

      def walk_lifecycle(agg, depth, &block)
        return unless agg.lifecycle

        yield agg.lifecycle, depth, "lifecycle"
        agg.lifecycle.transitions.each do |cmd, transition|
          yield transition, depth + 1, "transition:#{cmd}"
        end
      end

      def walk_commands(agg, depth, &block)
        agg.commands.each_with_index do |cmd, idx|
          event = agg.events[idx]
          yield cmd, depth, "command"
          cmd.attributes.each { |attr| yield attr, depth + 1, "param" }
          cmd.preconditions.each { |cond| yield cond, depth + 1, "precondition" }
          cmd.postconditions.each { |cond| yield cond, depth + 1, "postcondition" }
          yield event, depth + 1, "emits" if event
        end
      end

      def walk_events(agg, depth, &block)
        agg.events.compact.each do |ev|
          yield ev, depth, "event"
          ev.attributes.each { |attr| yield attr, depth + 1, "field" }
        end
      end

      def walk_queries(agg, depth, &block)
        agg.queries.each { |query| yield query, depth, "query" }
      end

      def walk_validations(agg, depth, &block)
        agg.validations.each { |validation| yield validation, depth, "validation" }
      end

      def walk_invariants(agg, depth, &block)
        agg.invariants.each { |inv| yield inv, depth, "invariant" }
      end

      def walk_policies(agg, depth, &block)
        agg.policies.each { |pol| yield pol, depth, "policy" }
      end

      def walk_scopes(agg, depth, &block)
        agg.scopes.each { |scope| yield scope, depth, "scope" }
      end

      def walk_specifications(agg, depth, &block)
        agg.specifications.each { |spec| yield spec, depth, "specification" }
      end

      def walk_subscribers(agg, depth, &block)
        agg.subscribers.each { |subscriber| yield subscriber, depth, "subscriber" }
      end

      def walk_references(agg, depth, &block)
        (agg.references || []).each { |ref| yield ref, depth, "reference" }
      end
    end
  end
end
