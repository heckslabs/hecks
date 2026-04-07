# = Hecks::Chapters::Templating::SmokeTestChildren
#
# Paragraph listing the child modules of HecksTemplating::SmokeTest:
# event checks, behavior tests, and form submission.
#
#   Hecks::Chapters.load_aggregates(
#     Hecks::Chapters::Templating::SmokeTestChildren,
#     base_dir: File.expand_path("smoke_test", __dir__)
#   )
#
module Hecks
  module Chapters
    module Templating
      # Hecks::Chapters::Templating::SmokeTestChildren
      #
      # Paragraph for SmokeTest child modules: EventChecks, BehaviorTests, FormSubmission.
      #
      module SmokeTestChildren
        def self.define(b)
          b.aggregate "EventChecks", "Validates event log entries via /_events endpoint" do
            command("CheckEventsContain") { attribute :expected_events, String }
          end

          b.aggregate "BehaviorTests", "Composite mixin aggregating all domain behavior smoke tests" do
            command("TestQueries")
            command("TestPolicies")
            command("TestLifecycles")
          end

          b.aggregate "FormSubmission", "Navigates to forms, fills fields, and submits via POST" do
            command("SubmitForm") { attribute :form_path, String }
          end
        end
      end
    end
  end
end
