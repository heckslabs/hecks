require "json"
require_relative "removals"
require_relative "tokens"

module Hecks
  module Fuzzing
    module DomainGenerator
      # Shrinking a blueprint: the single removals that can be tried, and the pruning that drops
      # whatever a removal left dangling.
      module Pruning
        include Removals
        include Tokens

        # Identity attributes and creating commands are never offered for
        # removal — without them there is no domain left to dispatch against.
        def shrink_candidates(blueprint)
          removals(blueprint).map { |path| prune(remove_at(blueprint, path)) }.uniq.reject { |candidate| candidate == blueprint }
        end

        # Repeatedly drops whatever a removal left dangling, using each
        # element's `requires` tokens — set arithmetic, never a re-read of
        # the rendered source.
        def prune(blueprint)
          current = JSON.parse(JSON.generate(blueprint))
          loop do
            available = tokens(current)
            before = JSON.generate(current)
            prune_once!(current, available)
            break if JSON.generate(current) == before
          end
          current
        end

        def prune_once!(blueprint, available)
          keep = ->(item) { Array(item["requires"]).all? { |token| available.include?(token) } }
          blueprint["policies"].select!(&keep)
          blueprint["aggregates"].each { |aggregate| prune_aggregate!(aggregate, available, keep) }
        end

        def prune_aggregate!(aggregate, available, keep)
          aggregate["references"].select! { |target| available.include?("aggregate:#{target}") }
          %w[attributes invariants entities].each { |key| aggregate[key].select!(&keep) }
          prune_queries!(aggregate, keep)
          [aggregate, *aggregate["entities"]].each { |owner| prune_owner!(owner, available) }
        end

        def prune_queries!(aggregate, keep)
          aggregate["queries"].each { |query| query["wheres"].select!(&keep) }
          aggregate["queries"].select! { |query| query["wheres"].any? }
        end

        # The lifecycle and commands of an aggregate or one of its entities.
        def prune_owner!(owner, available)
          prune_lifecycle!(owner, available)
          owner["commands"].each { |command| prune_command!(command, available) }
        end

        def prune_lifecycle!(owner, available)
          return unless owner["lifecycle"]

          transitions = owner["lifecycle"]["transitions"]
          transitions.select! { |t| available.include?(t["requires"].first) }
          reachable = reachable_states(owner["lifecycle"]["default"], transitions)
          transitions.select! { |t| leaves_reached_state?(t, reachable) }
          owner["lifecycle"] = nil if transitions.empty?
        end

        def leaves_reached_state?(transition, reachable) = transition["from"].any? { |state| reachable.include?(state) }

        # A transition out of an unreached state can never fire; leaving one
        # behind after a shrink is a dead transition `hecks model_check` reports.
        def reachable_states(default, transitions)
          reachable = [default]
          loop do
            reached = transitions.select { |t| leaves_reached_state?(t, reachable) }.map { |t| t["to"] }
            return reachable if (reached - reachable).empty?

            reachable |= reached
          end
        end

        def prune_command!(command, available)
          keep = ->(item) { Array(item["requires"]).all? { |token| available.include?(token) } }
          command["references"].select! { |target| available.include?("aggregate:#{target}") }
          %w[args givens sets].each { |key| command[key].select!(&keep) }
        end
      end
    end
  end
end
