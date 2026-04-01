# Hecks::Workshop::Tour::SketchSteps
#
# Tour step definitions for the sketch phase: creating an aggregate,
# adding attributes, lifecycle, transitions, commands, browsing,
# validating, and describing the domain.
#
#   include SketchSteps
#   create_aggregate_step  # => Tour::Step
#
module Hecks
  class Workshop
    class Tour
      module SketchSteps
        def create_aggregate_step
          Step.new(
            title: "Create an aggregate",
            explanation: "Aggregates are the main building blocks of your domain.\n" \
                         "Let's create a Post aggregate.",
            code: 'aggregate("Post")',
            action: ->(r) { r.aggregate("Post") }
          )
        end

        def add_title_step
          Step.new(
            title: "Add a title attribute",
            explanation: "Attributes define the data an aggregate holds.",
            code: "Post.title String",
            action: ->(r) { r.aggregate("Post").attr(:title, String) }
          )
        end

        def add_body_step
          Step.new(
            title: "Add a body attribute",
            explanation: "Add another attribute for the post content.",
            code: "Post.body String",
            action: ->(r) { r.aggregate("Post").attr(:body, String) }
          )
        end

        def add_lifecycle_step
          Step.new(
            title: "Add a lifecycle",
            explanation: "Lifecycles track state transitions.\n" \
                         "This adds a status field defaulting to \"draft\".",
            code: 'Post.lifecycle :status, default: "draft"',
            action: ->(r) { r.aggregate("Post").lifecycle(:status, default: "draft") }
          )
        end

        def add_transition_step
          Step.new(
            title: "Add a transition",
            explanation: "Transitions define how status changes.\n" \
                         "PublishPost will move status to \"published\".",
            code: 'Post.transition "PublishPost" => "published"',
            action: ->(r) { r.aggregate("Post").transition("PublishPost" => "published") }
          )
        end

        def add_create_command_step
          Step.new(
            title: "Add a create command with attributes",
            explanation: "Commands represent actions users can take.\n" \
                         "CreatePost accepts title and body, and emits a CreatedPost event.",
            code: 'Post.command("CreatePost") { attribute :title, String; attribute :body, String }',
            action: ->(r) {
              r.aggregate("Post").command("CreatePost") do
                attribute :title, String
                attribute :body, String
              end
            }
          )
        end

        def browse_step
          Step.new(
            title: "Browse the domain",
            explanation: "The system browser shows a tree of your domain structure.",
            code: "browse",
            action: ->(r) { r.browse }
          )
        end

        def validate_step
          Step.new(
            title: "Validate the domain",
            explanation: "Check that the domain is well-formed before going live.",
            code: "validate",
            action: ->(r) {
              result = r.validate
              puts result ? "Domain is valid!" : "Domain has errors."
            }
          )
        end

        def describe_step
          Step.new(
            title: "Describe the domain",
            explanation: "See a full summary of aggregates, attributes, and commands.",
            code: "describe",
            action: ->(r) { r.describe }
          )
        end
      end
    end
  end
end
