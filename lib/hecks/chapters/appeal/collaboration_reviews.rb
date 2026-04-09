# Hecks::Chapters::Appeal::CollaborationReviewsParagraph
#
# Domain paragraph for the collaboration chapter of HecksAppeal.
# Defines aggregates for change reviews, element annotations,
# and AI assistant interactions.
#
#   Hecks::Chapters::Appeal::CollaborationReviewsParagraph.define(builder)
#
module Hecks
  module Chapters
    module Appeal
      module CollaborationReviewsParagraph
        def self.define(b)
          b.aggregate "Review" do
            description "Domain change review workflow -- propose changes, discuss, approve or reject."
            attribute :title, String
            attribute :status, String, default: "open"
            attribute :author, String
            attribute :changes_summary, String
            attribute :comments, list_of("ReviewComment")

            value_object "ReviewComment" do
              description "A comment on a proposed domain change"
              attribute :author, String
              attribute :body, String
              attribute :element_name, String
              attribute :timestamp, String
            end

            command "ProposeChange" do
              description "Open a review for a set of domain changes"
              attribute :title, String
              attribute :author, String
              attribute :changes_summary, String
            end

            command "AddComment" do
              description "Comment on the proposed changes"
              attribute :author, String
              attribute :body, String
              attribute :element_name, String
            end

            command "ApproveReview" do
              description "Approve the proposed domain changes"
              attribute :author, String
            end

            command "RejectReview" do
              description "Reject the proposed changes with a reason"
              attribute :author, String
              attribute :reason, String
            end

            validation :title, presence: true
          end

          b.aggregate "Annotation" do
            description "Comments and notes attached to specific domain elements."
            attribute :element_type, String
            attribute :element_name, String
            attribute :body, String
            attribute :resolved, String, default: "false"
            attribute :replies, list_of("Reply")

            value_object "Reply" do
              description "A threaded reply to an annotation"
              attribute :author, String
              attribute :body, String
              attribute :timestamp, String
            end

            command "Annotate" do
              description "Attach a comment to a domain element"
              attribute :element_type, String
              attribute :element_name, String
              attribute :body, String
            end

            command "ResolveAnnotation" do
              description "Mark an annotation as resolved"
              end

            command "ReplyToAnnotation" do
              description "Add a threaded reply to an existing annotation"
              attribute :author, String
              attribute :body, String
            end

            query "Unresolved" do
              where(resolved: "false")
            end
          end

          b.aggregate "Agent" do
            description "AI assistant for domain modeling. Ask questions, get suggestions, apply changes."
            attribute :adapter_mode, String
            attribute :thinking, String
            attribute :messages, list_of("Message")
            attribute :suggestions, list_of("Suggestion")
            attribute :loaded_domain, String

            value_object "Message" do
              description "A conversation message -- user or assistant"
              attribute :role, String
              attribute :content, String
              attribute :timestamp, String
            end

            value_object "Suggestion" do
              description "A proposed domain change with rationale and diff preview"
              attribute :title, String
              attribute :rationale, String
              attribute :diff_preview, String
              attribute :status, String, default: "pending"
            end

            command "SendMessage" do
              description "Send a message to the AI assistant about the domain"
              attribute :content, String
              emits "MessageReceived"
            end

            command "ToggleAdapter" do
              description "Switch between memory and live LLM adapter"
              attribute :mode, String
              emits "AdapterChanged"
            end

            command "ClearConversation" do
              description "Reset the conversation history"
              emits "ConversationCleared"
            end

            command "ApplySuggestion" do
              description "Accept and apply a suggested domain change"
              attribute :title, String
              emits "SuggestionApplied"
            end

            command "RequestReview" do
              description "Ask the AI to review the current domain"
              emits "ReviewRequested"
            end

            command "LoadDomainContext" do
              description "Set which domain the agent introspects for tools and system prompt"
              attribute :domain_name, String
              emits "DomainContextLoaded"
            end

            lifecycle :adapter_mode, default: "memory" do
              transition "ToggleAdapter" => "live", from: "memory"
              transition "ToggleAdapter" => "memory", from: "live"
            end

            lifecycle :thinking, default: "idle" do
              transition "SendMessage" => "thinking", from: "idle"
              transition "ReceiveResponse" => "idle", from: "thinking"
            end
          end
        end
      end
    end
  end
end
