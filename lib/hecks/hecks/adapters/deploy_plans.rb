# frozen_string_literal: true

module Hecks
  module Adapters
    # The plan a write to AWS prints when it is refused unconfirmed or run with `dry_run`: what the
    # project's script would do, read from the script's own text, so nothing is run to say it.
    module DeployPlans
      module_function

      # What `preview.sh <action>` would do for a branch.
      #
      # @param text [String] the preview script's source
      # @param action [String] `deploy`, `destroy` or `login`
      # @param branch [String, nil] the branch named, or nil for the checked-out one
      # @return [String]
      def preview(text, action, branch)
        stack = "#{variable(text, 'PREFIX') || '<prefix>'}-<name derived from #{branch || 'the checked-out branch'}>"
        region = variable(text, "REGION")
        where = region ? " in #{region}" : ""
        case action
        when "deploy"
          "push the locally built images and create or update the preview stack #{stack}#{where}, " \
          "create its database and start its service"
        when "destroy" then "empty the preview's storage and delete the preview stack #{stack}#{where}"
        else "read the session secret of the preview stack #{stack}#{where} and mint a signed-in admin session"
        end
      end

      # What `deploy-<companion>.sh` would roll, and onto which box.
      #
      # @param text [String] the companion script's source
      # @param companion [String] the companion's name
      # @param taskdef [String] the task definition its image and settings are read from
      # @return [String]
      def companion(text, companion, taskdef)
        stack = text[/out\s+(\S+)\s+InstanceId/, 1]
        project = text[/compose -p (\w+)/, 1] || companion
        directory = text[%r{mkdir -p (/\S+)}, 1]
        place = directory ? " in #{directory}" : String.new
        "roll #{companion} (Compose project #{project}#{place}) from task definition " \
          "#{taskdef} onto the box of stack #{stack || '<box stack>'} over SSM, beside the app's project, " \
          "then check it on the box"
      end

      # The value a script assigns to an upper-case variable at the start of a line.
      def variable(text, name) = text[/^#{name}=["']?([^"'\s]+)/, 1]
    end
  end
end
