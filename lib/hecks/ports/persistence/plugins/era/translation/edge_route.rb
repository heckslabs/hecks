# frozen_string_literal: true

module Hecks
  module Translation
    # Finds the run of translation edges that leads one shape label to another. A run is found by
    # search rather than by walking every label's edges, so an edge that leaves a label off the run
    # (a fork branch) does not stop the route.
    module EdgeRoute
      module_function

      # The shortest run of edges from one label to another.
      #
      # @return [Array<Bluebook::Translation>] the edges in order; when `from` is `to`, the self
      #   edge if one exists, else empty
      # @raise [Runtime::WiringError] when no run of edges leads `from` to `to`
      def route(edges, from, to)
        return edges.select { |edge| edge.from == from && edge.to == from }.first(1) if from == to

        walk(edges, from, to).fetch(to) { raise Runtime::WiringError, "no translation edge leads #{from} to #{to}" }
      end

      # Breadth-first over labels, keeping the first run found to each one.
      #
      # @return [Hash{String => Array<Bluebook::Translation>}] the run to each reached label
      def walk(edges, from, to)
        paths = { from => [] }
        frontier = [from]
        until frontier.empty? || paths.key?(to)
          label = frontier.shift
          extend_runs(paths, frontier, edges, label)
        end
        paths
      end

      def extend_runs(paths, frontier, edges, label)
        edges.each do |edge|
          next unless edge.from == label && !paths.key?(edge.to)

          paths[edge.to] = [*paths[label], edge]
          frontier << edge.to
        end
      end

      # @return [Boolean] whether a run of edges leads from one label to another
      def reachable?(from, to, edges) = reached(from, edges).include?(to)

      # @return [Array<String>] every label reachable from `from`, `from` included
      def reached(from, edges)
        seen = [from]
        frontier = [from]
        until frontier.empty?
          label = frontier.shift
          successors = edges.filter_map { |edge| edge.to if edge.from == label && !seen.include?(edge.to) }
          seen.concat(successors)
          frontier.concat(successors)
        end
        seen
      end
    end
  end
end
