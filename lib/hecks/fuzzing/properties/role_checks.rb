module Hecks
  module Fuzzing
    module Properties
      # Property: the role check at dispatch agrees with the grants the replay itself made.
      #
      # `CommandRules::Authorization` asks the authorization provider whether an identified caller
      # holds a command's role, through the `assignments` verb the provider's chapter declares with
      # `provides "authorization"`. Each `history[:role_checks]` entry carries the grants read back
      # through that same verb before the dispatch, so the answer is recomputed from them.
      module RoleChecks
        # How `Replay.refusal_kind` names the refusal the role gate raises.
        UNAUTHORIZED = "Hecks::Runtime::Unauthorized".freeze

        # An identified caller holding a live grant of the role is never refused as unauthorized,
        # and one holding none is never accepted.
        #
        # A refusal other than Unauthorized proves nothing about the grant: argument gates run
        # before the role gate, so an ungranted caller can be turned away for another reason first.
        #
        # @param history [Hash] a replayed history, as returned by `Fuzzing::Replay.call`
        # @return [true, String] true, or a message naming each dispatch the grants contradict
        def role_checks_agree_with_grants(history)
          offenders = Array(history[:role_checks]).filter_map { |check| role_check_offender(check) }
          offenders.empty? || offenders.uniq.join("; ")
        end

        # One message when `check`'s outcome contradicts its grants; nil when consistent or inconclusive.
        def role_check_offender(check)
          held = role_held?(check)
          return refused_message(check) if held && check[:outcome] == UNAUTHORIZED

          accepted_message(check) if !held && check[:outcome].nil?
        end

        def role_held?(check)
          check[:grants].any? { |grant| grant[:role] == check[:role] && !grant[:ended] }
        end

        def refused_message(check)
          "#{check[:verb]} was refused as unauthorized for #{check[:actor_id]}, who holds a live grant of " \
            "#{check[:role].inspect}"
        end

        def accepted_message(check)
          "#{check[:verb]} was accepted for #{check[:actor_id]}, who holds no live grant of #{check[:role].inspect}"
        end
      end
    end
  end
end
