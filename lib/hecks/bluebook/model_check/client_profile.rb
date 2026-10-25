module Hecks
  module Bluebook
    module ModelCheck
      # The opt-in `client` profile: refuses bluebook constructs already known
      # to produce a silently wrong answer, so a client domain can't reach one
      # unnoticed.
      #
      # Each rule names a bug that is still open; delete the rule when the bug is fixed.
      module ClientProfile
        # The rule methods `call` runs, each answering `(bluebook, hecksagon)` with its findings.
        # None is open. A rooted read model a projection answers natively is not refused:
        # `Fuzzing::ProjectionAgreement` checks it against the in-process loop (ADR 0122).
        RULES = [].freeze

        module_function

        # Runs every client-profile rule over one chapter.
        #
        # @param bluebook [Bluebook::Chapter] the assembled chapter to check
        # @param hecksagon [Bluebook::Hecksagon, nil] the chapter's sibling wiring file
        # @return [Array<ModelCheck::Finding>] one error-severity finding per construct refused
        def call(bluebook, hecksagon: nil)
          RULES.flat_map { |rule| public_send(rule, bluebook, hecksagon) }
        end

        # Builds one error-severity finding of this profile.
        #
        # @param kind [Symbol] the finding's kind, one of the `:client_*` rules above
        # @param subject [String] the read model or `Domain::Aggregate` the finding is about
        # @param message [String] what was found, why it is refused, and where it is tracked
        # @return [ModelCheck::Finding] an `:error` finding
        def finding(kind, subject, message)
          ModelCheck::Finding.new(kind: kind, severity: :error, subject: subject, message: message)
        end
      end
    end
  end
end
