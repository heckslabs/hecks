# frozen_string_literal: true

require_relative "compose"
require_relative "edge_route"
require_relative "compose_render"
require_relative "edge_files"

module Hecks
  module Translation
    # Plans `SchemaRevision.Reconcile` for a domain: the edge that leads its latest held era to the
    # current shape, the edge files that edge supersedes, and the named reason a plan is refused.
    #
    # Planning reads the held labels, the loaded edges and the edge files, and writes nothing;
    # `ReconcileFiles` carries out an admitted plan.
    module Reconcile
      # What a plan is made from: the domain's name, its held eras (`ordinal:` and `label:`, in
      # order), the current shape's label, its loaded edges, the edge files of its translations
      # directory and the directory a composed edge is written under.
      Scope = Struct.new(:domain, :held, :current, :edges, :files, :directory, keyword_init: true)

      # One domain's plan. `status` is `:no_era`, `:clean`, `:write` or `:refused`; `latest` is the
      # latest held era (`ordinal:`, `label:`); `edge` is the composed edge when one is needed, and
      # `removals` the edge files the plan deletes; `refusal` names why a plan is refused.
      Plan = Struct.new(:domain, :status, :latest, :current, :labels, :edge, :write_path, :text,
                        :removals, :mints, :refusal, keyword_init: true)

      module_function

      # @param scope [Scope] what the plan is made from
      # @return [Plan] the plan; `status` is `:refused` with `refusal` naming the reason
      def plan(scope)
        return Plan.new(domain: scope.domain, status: :no_era, current: scope.current) if scope.held.empty?

        latest = scope.held.last
        decide(scope, latest, composition(scope, latest))
      rescue Runtime::WiringError => e
        Plan.new(domain: scope.domain, status: :refused, latest: scope.held.last, current: scope.current,
                 refusal: e.message)
      end

      # @return [Hash] `chain:` the edges from the latest era, `edge:` the composed edge when the
      #   chain has more than one step, and `kept:` the edge that already leads to the current shape
      def composition(scope, latest)
        chain = EdgeRoute.route(scope.edges, latest[:label], scope.current)
        return { chain: chain, edge: nil, kept: chain.first } if chain.size <= 1

        edge = Compose.compose(domain: scope.domain, from: latest[:label], to: scope.current, chain: chain)
        { chain: chain, edge: edge, kept: edge }
      end

      def decide(scope, latest, composition)
        removed = superseded(composition, scope.edges, latest)
        refusal = refusal_for(scope, removed, composition)
        return refused(scope, latest, refusal) if refusal

        verdict(scope, latest, composition, removed.map { |edge| file_for!(scope, edge) })
      end

      # The edges a composed plan replaces: every chain step when the chain is composed, and every
      # other edge leaving the latest held era.
      def superseded(composition, edges, latest)
        steps = composition[:chain].size > 1 ? composition[:chain] : []
        branches = edges.select { |edge| edge.from == latest[:label] && !same?(edge, composition[:kept]) }
        (steps + branches).uniq { |edge| key(edge) }
      end

      # The named reason the change is refused: an earlier era still using an edge the change
      # deletes, or an earlier era the change would leave with no way to the current shape.
      def refusal_for(scope, removed, composition)
        after = scope.edges.reject { |edge| removed.any? { |gone| same?(gone, edge) } }
        after += [composition[:edge]] if composition[:edge]
        earlier = scope.held[0...-1]
        still_used(scope.domain, earlier, removed) || uncovered(scope, earlier, after)
      end

      def still_used(domain, earlier, removed)
        removed.each do |edge|
          era = earlier.find { |held| held[:label] == edge.from }
          next unless era

          return "#{domain}: era #{era[:ordinal]} (#{era[:label]}) still uses the edge #{edge.from} -> " \
                 "#{edge.to}, which the change would delete"
        end
        nil
      end

      def uncovered(scope, earlier, after)
        era = earlier.find { |held| !EdgeRoute.reachable?(held[:label], scope.current, after) }
        return nil unless era

        verb = EdgeRoute.reachable?(era[:label], scope.current, scope.edges) ? "the change would leave" : "no edge leads"
        "#{scope.domain}: #{verb} era #{era[:ordinal]} (#{era[:label]}) a way to #{scope.current}"
      end

      def verdict(scope, latest, composition, removal_paths)
        labels = [latest[:label], *composition[:chain].map(&:to)]
        edge = composition[:edge]
        status = edge || removal_paths.any? ? :write : :clean
        Plan.new(domain: scope.domain, status: status, latest: latest, current: scope.current, labels: labels,
                 edge: edge, write_path: write_path_for(scope, latest, edge),
                 text: edge && ComposeRender.render(edge, labels: labels), removals: removal_paths,
                 mints: latest[:label] != scope.current)
      end

      def write_path_for(scope, latest, edge)
        return nil unless edge

        EdgeFiles.path_for(scope.directory, from: latest[:label], to: scope.current)
      end

      def refused(scope, latest, refusal)
        Plan.new(domain: scope.domain, status: :refused, latest: latest, current: scope.current, refusal: refusal)
      end

      # @return [String] the path of the edge file that carries `edge`
      # @raise [Runtime::WiringError] when no file under the translations directory holds it
      def file_for!(scope, edge)
        found = scope.files.find { |file| file.domain == scope.domain && file.from == edge.from && file.to == edge.to }
        return found.path if found

        raise Runtime::WiringError,
              "#{scope.domain}: no edge file holds #{edge.from} -> #{edge.to}, so it cannot be removed"
      end

      def same?(left, right) = !right.nil? && key(left) == key(right)

      def key(edge) = [edge.from, edge.to]
    end
  end
end
