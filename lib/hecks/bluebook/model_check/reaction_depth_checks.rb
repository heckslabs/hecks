require_relative "reaction_chains"

module Hecks
  module Bluebook
    module ModelCheck
      # The checks over reaction chains. A command whose events start a chain of policies longer
      # than the dispatcher's reaction limit has the reactions past it refused without anyone
      # being told; a chain of exactly the limit runs whole, in both runtimes. A loop of
      # policies, which no limit on the chain's length can describe, is reported as a loop.
      module ReactionDepthChecks
        # @param bluebook [Bluebook::Declaration] the assembled bluebook, its hecksagon attached
        # @param limit [Integer] the reaction depth limit; the dispatcher's own when not given
        # @return [Array<Finding>] a warning for each entry command whose longest chain exceeds
        #   `limit`, for each loop of policies, and for each chain search that gave up
        def reaction_depth_findings(bluebook, limit: Hecks::Runtime::Dispatcher::MAX_REACTION_DEPTH)
          chains = ReactionChains.new(bluebook)
          [*(chains.verbs - chains.reaction_targets.to_a).flat_map { |verb| chain_findings(chains, verb, limit) },
           *chains.cycles.map { |policies| loop_finding(policies, limit) }]
        end

        # @return [Array<Finding>] the deep-chain warning for the verb, and the search warning if
        #   the walk gave up
        def chain_findings(chains, verb, limit)
          chain = chains.from(verb)
          [(deep_chain_finding(verb, chain, limit) if chain.size > limit),
           (capped_search_finding(verb, chain) if chains.capped?)].compact
        end

        # @return [Finding] the warning naming every policy of a loop
        def loop_finding(policies, limit)
          names = policies.map(&:name)
          Finding.new(kind: :unbounded_reaction_loop, severity: :warning, subject: names.join(", "),
                      message: "policies #{names.join(", ")} reach one another, so a command that starts " \
                               "them reacts until the reaction depth limit of #{limit}, and the " \
                               "#{limit + 1}th reaction is refused without anyone being told")
        end

        # @return [Finding] the warning that the chain found for the verb is a lower bound
        def capped_search_finding(verb, chain)
          Finding.new(kind: :reaction_chain_search_capped, severity: :warning, subject: verb_text(verb),
                      message: "the search for the longest chain stopped after " \
                               "#{ReactionWalk::WORK_LIMIT} steps; the chain of #{chain.size} reactions is a lower bound")
        end

        # @return [Finding] the warning naming the entry verb and each policy and verb of its chain
        def deep_chain_finding(verb, chain, limit)
          path = chain.map { |step| "#{step.policy_name} -> #{verb_text(step.verb)}" }.join(" -> ")
          Finding.new(kind: :deep_reaction_chain, severity: :warning, subject: verb_text(verb),
                      message: "starts a chain of #{chain.size} reactions, past the reaction depth " \
                               "limit of #{limit}: the #{limit + 1}th and any after it are refused: " \
                               "#{verb_text(verb)} -> #{path}")
        end

        def verb_text(verb) = "#{verb[0]}::#{verb[1]}.#{verb[2]}"
      end
    end
  end
end
