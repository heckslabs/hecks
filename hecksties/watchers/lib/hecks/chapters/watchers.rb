# Hecks::Chapters::Watchers
#
# Self-describing chapter for the HecksWatchers component. Covers file
# watchers, the polling runner, pre-commit hook consolidation, logging,
# and the watcher registry.
#
#   domain = Hecks::Chapters::Watchers.definition
#   domain.aggregates.map(&:name)
#
require "bluebook"

module Hecks
  module Chapters
    module Watchers
      def self.definition
        DSL::DomainBuilder.new("Watchers").tap { |b|
          b.aggregate "WatcherRegistry" do
            description "Registry for pre-commit watchers, categorized as blocking or advisory"
            command "RegisterWatcher" do
              attribute :kind, String
              attribute :watcher_class, String
            end
            command "ListBlocking"
            command "ListAdvisory"
          end

          b.aggregate "FileSize" do
            description "Advisory watcher that warns when staged files exceed the 200-line code limit"
            command "Check" do
              attribute :project_root, String
            end
          end

          b.aggregate "CrossRequire" do
            description "Blocking watcher that prevents require_relative from escaping component boundaries"
            command "Check" do
              attribute :project_root, String
            end
          end

          b.aggregate "SpecCoverage" do
            description "Advisory watcher that warns when new lib files lack corresponding specs"
            command "Check" do
              attribute :project_root, String
            end
          end

          b.aggregate "DocReminder" do
            description "Advisory watcher that reminds about FEATURES.md and CHANGELOG updates"
            command "Check" do
              attribute :project_root, String
            end
          end

          b.aggregate "Runner" do
            description "Polls for file changes every second and runs all watchers on change"
            command "Start" do
              attribute :project_root, String
            end
            command "CheckOnce"
          end

          b.aggregate "PreCommit" do
            description "Consolidates all watchers into a single pre-commit check"
            command "Run" do
              attribute :project_root, String
            end
          end

          b.aggregate "Logger" do
            description "Shared logging to stdout and tmp/watcher.log for Claude hook integration"
            command "Log" do
              attribute :message, String
            end
          end

          b.aggregate "LogReader" do
            description "Reads and clears watcher log for PostToolUse hook consumption"
            command "Read" do
              attribute :project_root, String
            end
          end
        }.build
      end
    end
  end
end
