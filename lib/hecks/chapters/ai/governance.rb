# Hecks::Chapters::AI::GovernanceParagraph
#
# Paragraph listing the GovernanceGuard child aggregates:
# GovernanceResult and ConcernChecks. Used by load_aggregates
# to derive require paths from aggregate names.
#
#   Hecks::Chapters.load_aggregates(
#     Hecks::Chapters::AI::GovernanceParagraph,
#     base_dir: File.expand_path("governance_guard", __dir__)
#   )
#
module Hecks
  module Chapters
    module AI
      module GovernanceParagraph
        def self.define(b)
          b.aggregate "GovernanceResult" do
            description "Immutable result object from a governance check with violations and suggestions"
            command "Create" do
              attribute :violations, String
              attribute :suggestions, String
            end
          end

          b.aggregate "ConcernChecks" do
            description "Rule-based governance checks for transparency, consent, privacy, security"
            command "CheckTransparency"
            command "CheckConsent"
            command "CheckPrivacy"
            command "CheckSecurity"
          end
        end
      end
    end
  end
end
