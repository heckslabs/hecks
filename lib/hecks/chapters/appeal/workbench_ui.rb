# Hecks::Chapters::Appeal::WorkbenchUiParagraph
#
# Domain paragraph for the workbench chapter of HecksAppeal.
# Defines aggregates for notifications, screenshot debugging,
# full-text search, and cross-domain reactive policies.
#
#   Hecks::Chapters::Appeal::WorkbenchUiParagraph.define(builder)
#
module Hecks
  module Chapters
    module Appeal
      module WorkbenchUiParagraph
        def self.define(b)
          b.aggregate "Notification" do
            description "Feedback messages -- errors, warnings, success confirmations, progress updates."
            attribute :severity, String
            attribute :message, String
            attribute :context, String
            attribute :dismissed, String, default: "false"

            command "Notify" do
              description "Create a notification for the user"
              attribute :severity, String
              attribute :message, String
              attribute :context, String
              emits "Notified"
            end

            command "DismissNotification" do
              description "Mark a notification as seen"
              emits "NotificationDismissed"
            end

            query "Active" do
              where(dismissed: "false")
            end
          end

          b.aggregate "Screenshot" do
            description "Rolling buffer of browser screenshots for visual debugging."
            attribute :buffer_size, Integer, default: 100
            attribute :capture_interval, Integer, default: 1000
            attribute :status, String, default: "streaming"

            command "CaptureScreen" do
              description "Save a screenshot frame from the browser"
              attribute :frame_data, String
              attribute :timestamp, String
              emits "ScreenshotCaptured"
            end

            command "PauseCapture" do
              description "Stop capturing screenshots"
              emits "CapturePaused"
            end

            command "ResumeCapture" do
              description "Resume capturing screenshots"
              emits "CaptureResumed"
            end
          end

          b.aggregate "Search" do
            description "Full-text search across domains, aggregates, commands, and attributes."
            attribute :query_text, String
            attribute :results, list_of("SearchResult")
            attribute :result_count, Integer, default: 0

            value_object "SearchResult" do
              description "A single search match with context"
              attribute :element_type, String
              attribute :element_name, String
              attribute :domain_name, String
              attribute :context, String
              attribute :relevance, Integer
            end

            command "SearchDomain" do
              description "Search across all domain elements for a query string"
              attribute :query_text, String
              emits "SearchCompleted"
            end

            command "ClearSearch" do
              description "Reset search results"
              emits "SearchCleared"
            end

            command "FilterSearchResults" do
              description "Narrow results by element type"
              attribute :element_type, String
              emits "SearchResultsFiltered"
            end
          end

          b.policy "SwitchToEditorOnFileOpen" do
            on "FileOpened"
            trigger "SelectTab"
            defaults tab: "editor"
          end
        end
      end
    end
  end
end
