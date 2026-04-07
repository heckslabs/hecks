# Hecks::Chapters::Bluebook::ValidationRulesParagraph
#
# Paragraph covering validation rule classes: the checks that
# enforce naming conventions, structural integrity, reference
# validity, and world concerns across domain definitions.
#
#   Hecks::Chapters::Bluebook::ValidationRulesParagraph.define(builder)
#
module Hecks
  module Chapters
    module Bluebook
      module ValidationRulesParagraph
        def self.define(b)
          b.aggregate "BaseRule", "Abstract base class for all domain validation rules" do
            command("RunRule") { attribute :domain_id, String }
          end

          b.aggregate "ValidationMessage", "Structured validation result with severity and context" do
            command("CreateMessage") { attribute :message, String; attribute :severity, String }
          end

          # Naming rules
          b.aggregate "CommandNaming", "Validates command names follow verb-noun convention" do
            command("CheckCommandNaming") { attribute :domain_id, String }
          end

          b.aggregate "UniqueAggregateNames", "Validates no duplicate aggregate names in domain" do
            command("CheckUniqueNames") { attribute :domain_id, String }
          end

          b.aggregate "SafeIdentifierNames", "Validates names are safe Ruby/Go identifiers" do
            command("CheckIdentifiers") { attribute :domain_id, String }
          end

          b.aggregate "ReservedNames", "Validates names do not clash with language reserved words" do
            command("CheckReservedNames") { attribute :domain_id, String }
          end

          b.aggregate "NameCollisions", "Detects naming collisions between aggregates and value objects" do
            command("CheckNameCollisions") { attribute :domain_id, String }
          end

          b.aggregate "ComputedNameCollisions", "Detects collisions between computed and declared attributes" do
            command("CheckComputedCollisions") { attribute :domain_id, String }
          end

          b.aggregate "GlossaryTermViolations", "Enforces ubiquitous language glossary term usage" do
            command("CheckGlossaryTerms") { attribute :domain_id, String }
          end

          # Structure rules
          b.aggregate "AggregatesHaveCommands", "Validates every aggregate has at least one command" do
            command("CheckAggregateCommands") { attribute :domain_id, String }
          end

          b.aggregate "CommandsHaveAttributes", "Validates commands declare at least one attribute" do
            command("CheckCommandAttributes") { attribute :domain_id, String }
          end

          b.aggregate "SingleAttributeAggregate", "Warns when aggregate has only one attribute" do
            command("CheckSingleAttribute") { attribute :domain_id, String }
          end

          b.aggregate "TooManyCommands", "Warns when aggregate has excessive commands" do
            command("CheckCommandCount") { attribute :domain_id, String }
          end

          b.aggregate "ValidPolicyEvents", "Validates policy event references exist in domain" do
            command("CheckPolicyEvents") { attribute :domain_id, String }
          end

          b.aggregate "ValidPolicyTriggers", "Validates policy trigger commands exist in domain" do
            command("CheckPolicyTriggers") { attribute :domain_id, String }
          end

          b.aggregate "NoPiiInIdentity", "Warns against PII fields used as identity attributes" do
            command("CheckPiiIdentity") { attribute :domain_id, String }
          end

          # Reference rules
          b.aggregate "ValidReferences", "Validates reference targets exist in domain" do
            command("CheckReferences") { attribute :domain_id, String }
          end

          b.aggregate "NoSelfReferences", "Detects invalid self-referencing aggregate associations" do
            command("CheckSelfReferences") { attribute :domain_id, String }
          end

          b.aggregate "NoBidirectionalReferences", "Detects bidirectional reference cycles between aggregates" do
            command("CheckBidirectional") { attribute :domain_id, String }
          end

          b.aggregate "NoForeignKeyAttributes", "Detects attributes that should be references instead" do
            command("CheckForeignKeys") { attribute :domain_id, String }
          end

          # World concerns
          b.aggregate "Transparency", "Validates domain design supports transparency concern" do
            command("CheckTransparency") { attribute :domain_id, String }
          end

          b.aggregate "Consent", "Validates domain design supports user consent concern" do
            command("CheckConsent") { attribute :domain_id, String }
          end

          b.aggregate "Privacy", "Validates domain design supports privacy concern" do
            command("CheckPrivacy") { attribute :domain_id, String }
          end

          b.aggregate "Security", "Validates domain design supports security concern" do
            command("CheckSecurity") { attribute :domain_id, String }
          end

          b.aggregate "BoundaryAdvisor", "Warns when aggregates are suspiciously thin (single attribute, no VOs)" do
            command("Advise") { attribute :domain_id, String }
          end

          b.aggregate "WorldConcerns", "Validates that aggregate world concerns are permitted by domain policy" do
            command("CheckConcerns") { attribute :domain_id, String }
          end
        end
      end
    end
  end
end
