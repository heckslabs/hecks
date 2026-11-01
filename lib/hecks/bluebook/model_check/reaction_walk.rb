module Hecks
  module Bluebook
    module ModelCheck
      # The longest chain of reactions a policy starts, counting each policy once per chain. A
      # policy that reaches no loop has one longest chain whatever path led to it, so those are
      # remembered; the rest are searched path by path, and the search stops after `WORK_LIMIT`
      # steps per chain, which `capped?` reports.
      class ReactionWalk
        # Policies visited by one search before it gives up and answers the best chain so far.
        WORK_LIMIT = 10_000

        # @param graph [ReactionChains] answers `step(policy)` and `successors(policy)`
        # @param looping [Array] the policies that lie on a loop
        def initialize(graph, looping)
          @graph   = graph
          @looping = looping.to_set
          @settled = {}
          @reaches = {}
          @work    = 0
        end

        # @param starts [Array] the policies the first event reaches
        # @return [Array<ReactionChains::Step>] the longest chain, in order
        def longest(starts)
          @work = 0
          @capped = false
          starts.map { |policy| search(policy, []) }.max_by(&:size) || []
        end

        # @return [Boolean] whether the last `longest` gave up, so its chain is a lower bound
        def capped? = @capped

        private

        def search(policy, path)
          return settled(policy) unless reaches_loop?(policy)
          return give_up if (@work += 1) > WORK_LIMIT

          open = @graph.successors(policy) - path - [policy]
          [@graph.step(policy)] + (open.map { |next_policy| search(next_policy, [*path, policy]) }.max_by(&:size) || [])
        end

        def give_up
          @capped = true
          []
        end

        def settled(policy)
          @settled[policy] ||= [@graph.step(policy)] +
                               (@graph.successors(policy).map { |next_policy| settled(next_policy) }.max_by(&:size) || [])
        end

        def reaches_loop?(policy)
          @reaches.fetch(policy) do
            onward = @graph.successors(policy)
            @reaches[policy] = @looping.include?(policy) || onward.any? { |next_policy| reaches_loop?(next_policy) }
          end
        end
      end
    end
  end
end
