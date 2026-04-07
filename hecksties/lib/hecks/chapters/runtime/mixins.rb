# = Hecks::Chapters::Runtime::Mixins
#
# Self-describing sub-chapter for runtime mixins: aggregate model,
# command dispatch, reference validation, lifecycle steps, and
# composite specification objects.
#
#   Hecks::Chapters::Runtime::Mixins.define(builder)
#
module Hecks
  module Chapters
    module Runtime
      # Hecks::Chapters::Runtime::Mixins
      #
      # Bluebook sub-chapter for runtime mixins: aggregate model, command dispatch, and specification objects.
      #
      module Mixins
        def self.define(b)
          b.aggregate "ModelMixinInternal", "Aggregate model mixin: attributes, equality, serialization" do
            command("Initialize") { attribute :attributes, String }
            command("Serialize") { attribute :format, String }
          end

          b.aggregate "DispatchMixin", "Command dispatch mixin" do
            command("Dispatch") { attribute :command_name, String; attribute :payload, String }
          end

          b.aggregate "ReferenceValidation", "Validates references exist before dispatch" do
            command("Validate") { attribute :reference_name, String; attribute :id, String }
          end

          b.aggregate "LifecycleSteps", "Lifecycle state transition steps" do
            command("Transition") { attribute :from_state, String; attribute :to_state, String }
          end

          b.aggregate "AndSpecification", "Composite AND specification" do
            command("Satisfied") { attribute :candidate, String }
          end

          b.aggregate "OrSpecification", "Composite OR specification" do
            command("Satisfied") { attribute :candidate, String }
          end

          b.aggregate "NotSpecification", "Composite NOT specification" do
            command("Satisfied") { attribute :candidate, String }
          end

          b.aggregate "BreakingBumper", "Auto-bumps version on breaking changes" do
            command("Bump") { attribute :domain_name, String }
          end

          b.aggregate "BreakingClassifier", "Classifies domain changes as breaking/non-breaking" do
            command("Classify") { attribute :diff, String }
          end
        end
      end
    end
  end
end
