module Hecks
  module SME
    module DiscoveryProjection
      # Places each accepted discovery Point in the bluebook body: a thing as an aggregate, a field
      # or an action inside the aggregate of the thing it names, and everything else (a rule, a
      # transition, a statement `Statement` cannot read, or a field or action whose thing nobody
      # accepted) as a cited comment above the aggregates.
      class Layout
        # @param points [Array<Hash>] the accepted discovery Points
        def initialize(points)
          @points = points
          @things = things
        end

        # @return [Array<String>] the body's lines, comments first, then one block per thing
        def lines
          blocks = @things.map do |name, point|
            AggregateText.lines(name, point, placed(:field, name), placed(:action, name))
          end
          notes = comments.map { |point| "#{DiscoveryProjection.cite(point)}: #{flat(point)}" }
          ([notes] + blocks).reject(&:empty?).flat_map { |block| [""] + block }
        end

        private

        # Each thing's name to the first Point that accepted it.
        def things
          read(:thing).map { |point, name| [name, point] }.uniq(&:first).to_h
        end

        # The `kind` Points read as belonging to the thing `name`, each with what it read.
        def placed(kind, name)
          read(kind).select { |_, parts| parts.first == name }.map { |point, parts| [point, *parts.drop(1)] }
        end

        # Every `kind` Point whose statement reads, with its parts.
        def read(kind)
          @points.select { |point| point[:kind] == kind.to_s }
                 .filter_map { |point| (parts = Statement.public_send(kind, point[:statement])) && [point, parts] }
        end

        # The Points no aggregate holds.
        def comments
          held = @things.values + %i[field action].flat_map { |kind| held_by_a_thing(kind) }
          @points.reject { |point| held.include?(point) }
        end

        def held_by_a_thing(kind)
          read(kind).select { |_, parts| @things.key?(parts.first) }.map(&:first)
        end

        def flat(point) = DiscoveryProjection.flat(point[:statement])
      end
    end
  end
end
