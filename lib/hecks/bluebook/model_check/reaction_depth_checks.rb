require_relative "reaction_chains"

module Hecks
  module Bluebook
    module ModelCheck
      # The check over reaction chains: a command whose events start a chain of policies as deep as
      # the dispatcher's reaction limit, where the last reactions are refused without anyone
      # being told.
      module ReactionDepthChecks
        # @param bluebook [Bluebook::Declaration] the assembled bluebook, its hecksagon attached
        # @param limit [Integer] the reaction depth limit; the dispatcher's own when not given
        # @return [Array<Finding>] one warning per entry command whose longest chain reaches `limit`
        def reaction_depth_findings(bluebook, limit: Hecks::Runtime::Dispatcher::MAX_REACTION_DEPTH)
          chains = ReactionChains.new(bluebook)
          (chains.verbs - chains.reaction_targets.to_a).filter_map do |verb|
            chain = chains.from(verb)
            deep_chain_finding(verb, chain, limit) if chain.size >= limit
          end
        end

        # @return [Finding] the warning naming the entry verb and each policy and verb of its chain
        def deep_chain_finding(verb, chain, limit)
          path = chain.map { |step| "#{step.policy_name} -> #{verb_text(step.verb)}" }.join(" -> ")
          Finding.new(kind: :deep_reaction_chain, severity: :warning, subject: verb_text(verb),
                      message: "starts a chain of #{chain.size} reactions, which reaches the reaction depth " \
                               "limit of #{limit} (Rust refuses the #{limit}th, Ruby the #{limit + 1}th): " \
                               "#{verb_text(verb)} -> #{path}")
        end

        def verb_text(verb) = "#{verb[0]}::#{verb[1]}.#{verb[2]}"
      end
    end
  end
end
