# frozen_string_literal: true

require "delegate"
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
          __WORLD_FILE__ declares no deployed_to("AwsLambda"), deployed_to("AwsFargate"), deployed_to("AwsBox"), deployed_to("AwsSharedDatabase") or deployed_to("Vercel") block. Add one, e.g.:

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

          or, for the RDS instance several sites share:

              deployed_to("AwsSharedDatabase") do
                region "us-east-1"
                stack_name "hecks-platform-rds"
              end

          or:

              deployed_to("Vercel") do
                region "iad1"
                env ["SESSION_SECRET"]
              end

          then re-run hecks deploy project __DOMAIN__.
        MSG

        # A world view whose `deployed_to` answers for one declared target, so a projector that
        # reads `world.for_verb("deployed_to")` sees that target's block and no other.
        class TargetWorld < SimpleDelegator
          # @param world [Object] the world the blocks were declared in
          # @param settings [Hash{Symbol => Object}] the one `deployed_to` block this view uses
          def initialize(world, settings)
            super(world)
            @settings = settings
          end

          # @return [Hash{Symbol => Object}] this target's block for `deployed_to`, else the world's
          def for_verb(verb) = verb.to_s == "deployed_to" ? @settings : super
        end

        # Every `deployed_to` block the world declares, in declaration order. The world records
        # each one as `deployed_to:<adapter>`; the plain `deployed_to` entry is only the last.
        #
        # @param world [Object] the loaded world
        # @return [Array<Hash{Symbol => Object}>] one settings hash per target, with its `:adapter`
        def declared_targets(world)
          world.settings.filter_map { |key, block| block if key.to_s.start_with?("deployed_to:") }
        end

        # @param blocks [Array<Hash>] the declared targets
        # @param wanted [String, nil] the `--target` flag
        # @return [Array<Hash>] the targets to generate: all, or the one named
        # @raise [SystemExit] when the world declares no such target
        def chosen_targets(blocks, wanted)
          return blocks unless wanted

          found = blocks.select { |block| block[:adapter].casecmp?(wanted) }
          return found unless found.empty?

          declared = blocks.map { |block| block[:adapter] }.join(", ")
          abort "no deployed_to(#{wanted.inspect}) is declared; declared: #{declared}"
        end

        # Each adapter maps to a registered `Projector` export (`needs_world: true`); this only
        # finds which one to call.
        #
        # @param deploy_settings [Hash] the world's `deployed_to` settings
        # @param world_file [String] the `.world` file, named in the refusal
        # @param domain [String] the domain directory, named in the refusal
        # @return [Symbol] the key of the registered projection, such as `:aws_box` or `:vercel`
        # @raise [SystemExit] with an example block when the world declares none of them
        def target_key(deploy_settings, world_file, domain)
          case deploy_settings[:adapter]
          when "AwsLambda" then :aws_lambda
          when "AwsFargate" then :aws_fargate
          when "AwsBox" then :aws_box
          when "AwsSharedDatabase" then :aws_shared_database
          when "Vercel" then :vercel
          else
            abort NO_TARGET.gsub("__WORLD_FILE__") { world_file }.gsub("__DOMAIN__") { domain }
          end
        end
      end
    end
  end
end
