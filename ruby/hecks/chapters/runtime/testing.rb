# = Hecks::Chapters::Runtime::Testing
#
# Self-describing sub-chapter for runtime testing support:
# browser-style HTTP smoke tests, event log validation, and
# domain behaviour verification.
#
#   Hecks::Chapters::Runtime::Testing.define(builder)
#
module Hecks
  module Chapters
    module Runtime
      # Hecks::Chapters::Runtime::Testing
      #
      # Bluebook sub-chapter for runtime testing: smoke tests, event checks, and behaviour verification.
      #
      module Testing
        def self.define(b)
          b.aggregate "SmokeTest", "Browser-style HTTP smoke tests for domains" do
            command("RunSmoke") { attribute :base_url, String }
            command("CheckEvents") { attribute :event_log, String }
            command("TestBehaviors") { attribute :domain_name, String }
          end
        end
      end
    end
  end
end
