require_relative "reaction_chains"

module Hecks
  module Bluebook
    module ModelCheck
      # The check over reaction chains: a command whose events start a chain of policies longer than
      # the dispatcher's reaction limit, where the reactions past it are refused without anyone
      # being told. A chain of exactly the limit runs whole, in both runtimes.
      module ReactionDepthChecks
        # @param bluebook [Bluebook::Declaration] the assembled bluebook, its hecksagon attached
        # @param limit [Integer] the reaction depth limit; the dispatcher's own when not given
        # @return [Array<Finding>] one warning per entry command whose longest chain exceeds `limit`
        def reaction_depth_findings(bluebook, limit: Hecks::Runtime::Dispatcher::MAX_REACTION_DEPTH)
          chains = ReactionChains.new(bluebook)
          (chains.verbs - chains.reaction_targets.to_a).filter_map do |verb|
            chain = chains.from(verb)
            deep_chain_finding(verb, chain, limit) if chain.size > limit
          end
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
