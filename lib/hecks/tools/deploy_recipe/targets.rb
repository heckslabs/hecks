# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module DeployRecipe
      # Which `deployed_to(...)` block a world declares, and what to tell a world that declares
      # none.
      module Targets
        # The refusal for a world with no deploy target, where `__WORLD_FILE__` and `__DOMAIN__`
        # stand for the world file and the domain directory.
        NO_TARGET = <<~MSG
          __WORLD_FILE__ declares no deployed_to("AwsLambda"), deployed_to("AwsFargate") or deployed_to("AwsBox") block. Add one, e.g.:

              deployed_to("AwsLambda") do
                region "us-east-1"
                memory 512
                timeout 10
              end

          or:

              deployed_to("AwsFargate") do
                region "us-east-1"
                cpu 256
                memory 512
                port 8080
              end

          or:

              deployed_to("AwsBox") do
                region "us-east-1"
                containers [{ name: "web", port: 8080 }]
              end

          then re-run hecks deploy project __DOMAIN__.
        MSG

        # Each adapter maps to a registered `Projector` export (`needs_world: true`); this only
        # finds which one to call.
        #
        # @param deploy_settings [Hash] the world's `deployed_to` settings
        # @param world_file [String] the `.world` file, named in the refusal
        # @param domain [String] the domain directory, named in the refusal
        # @return [Symbol] `:aws_lambda`, `:aws_fargate` or `:aws_box`
        # @raise [SystemExit] with an example block when the world declares none of them
        def target_key(deploy_settings, world_file, domain)
          case deploy_settings[:adapter]
          when "AwsLambda" then :aws_lambda
          when "AwsFargate" then :aws_fargate
          when "AwsBox" then :aws_box
          else
            abort NO_TARGET.gsub("__WORLD_FILE__") { world_file }.gsub("__DOMAIN__") { domain }
          end
        end
      end
    end
  end
end
