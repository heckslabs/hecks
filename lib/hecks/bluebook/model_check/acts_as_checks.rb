module Hecks
  module Bluebook
    module ModelCheck
      # The check over a policy's `acts_as`: the role a reaction dispatches as is only real once an
      # authorization provider (Governance) is attached to grant it (ADR 0216). It is a finding of
      # the model, not a refusal at boot: refusing an unstated caller is the runtime's to do.
      module ActsAsChecks
        # One finding per policy that says `acts_as` in a domain nothing can grant the role in.
        #
        # @param bluebook [Bluebook::Declaration] the domain being checked
        # @param hecksagon [Bluebook::Hecksagon, nil] its wiring; `nil` checks nothing, since
        #   without it what the domain attaches is unknown
        # @return [Array<Finding>] an `:ungoverned_acts_as` error for each such policy
        def acts_as_findings(bluebook, hecksagon)
          return [] if hecksagon.nil? || governed?(bluebook, hecksagon)

          bluebook.policies.reject { |policy| policy.acts_as.to_s.empty? }
                  .map { |policy| ungoverned_acts_as_finding(policy, hecksagon) }
        end

        # @return [Boolean] whether the domain provides authorization itself or attaches a
        #   framework member that does
        def governed?(bluebook, hecksagon)
          capability = Capabilities::AUTHORIZATION
          bluebook.provides?(capability) ||
            Hecks::Framework.providers_of(capability).any? { |name| hecksagon.attaches?(name) }
        end

        # @return [Finding] the error naming the policy, its role and what to attach
        def ungoverned_acts_as_finding(policy, hecksagon)
          providers = Hecks::Framework.providers_of(Capabilities::AUTHORIZATION).map(&:inspect).join(" or ")
          Finding.new(kind: :ungoverned_acts_as, severity: :error, subject: policy.name,
                      message: "acts_as #{policy.acts_as.inspect}, but #{hecksagon.domain}'s hecksagon " \
                               "attaches no authorization provider (#{providers}) to grant that role")
        end
      end
    end
  end
end
