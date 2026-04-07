# Hecks::Chapters::AI::IdeAggregates
#
# IDE-related aggregates for the AI chapter. Split from the main
# chapter to stay within the 200-line code limit.
#
#   Hecks::Chapters::AI::IdeAggregates.register(builder)
#
module Hecks
  module Chapters
    module AI
      module IdeAggregates
        def self.register(b)
          b.aggregate "IdeServer" do
            description "WEBrick server for the Hecks IDE with Claude streaming"
            command "Run"
          end

          b.aggregate "Routes" do
            description "HTTP route dispatch for the IDE server"
            command "ServePage"
            command "HandlePrompt"
          end

          b.aggregate "SessionRoutes" do
            description "HTTP route handlers for session resume, disconnect, history"
            command "HandleSessionResume"
            command "HandleDisconnect"
          end

          b.aggregate "ClaudeProcess" do
            description "Runs Claude Code in --print mode with stream-json output"
            command "SendPrompt" do
              attribute :prompt, String
            end
            command "Interrupt"
          end

          b.aggregate "BluebookDiscovery" do
            description "Discovers Bluebook and Hecksagon files, parses aggregate names"
            command "DiscoverApps"
          end

          b.aggregate "ContextBuilder" do
            description "Builds project context JSON for sidebar and Claude prompts"
            command "Build"
          end

          b.aggregate "PromptBuilder" do
            description "Assembles final prompt for Claude combining input, files, screenshots"
            command "Build" do
              attribute :user_input, String
            end
          end

          b.aggregate "SessionDiscovery" do
            description "Lists recent Claude Code sessions for the current project"
            command "ListRecent"
          end

          b.aggregate "SessionWatcher" do
            description "Tails Claude session JSONL file and emits new messages as IDE events"
            command "Start"
            command "Stop"
          end

          b.aggregate "ViewWatcher" do
            description "Watches views directory for changes and pushes reload events"
            command "Start"
          end

          b.aggregate "ScreenshotHandler" do
            description "Saves IDE screenshots to timestamped files, keeps last 20"
            command "Save" do
              attribute :base64_data, String
            end
          end

        end
      end
    end
  end
end
