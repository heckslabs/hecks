# frozen_string_literal: true

require_relative "../../tools"
require_relative "targets"

module Hecks
  module Tools
    module DeployRecipe
      # Writing the recipe for each `deployed_to` block a world declares: a client may declare
      # several deploy kinds (Vercel beside AwsBox), and each is generated, none locked out.
      module Generation
        # @param deployment [Deployment] what the generator resolved about the domain
        # @param root [String] the checkout
        # @return [String] `--out`, else `deploy/<name>` in the checkout
        def output_dir(deployment, root)
          out = deployment.options.out
          out ? File.expand_path(out) : File.join(root, "deploy", deployment.infra_name)
        end

        # One declared target, written straight into `out_dir` as it always was.
        #
        # @param block [Hash, nil] the target's settings; nil takes the world's plain `deployed_to`
        # @return [Integer] 0
        def generate_one(deployment, root, out_dir, block = nil)
          emit(block ? for_target(deployment, block) : deployment, root, out_dir)
          0
        end

        # Several declared targets, each under its own `out_dir/<adapter>` so their `Makefile`s and
        # scripts do not collide.
        #
        # @return [Integer] 0
        def generate_each(deployment, root, out_dir, blocks)
          blocks.each do |block|
            emit(for_target(deployment, block), root, File.join(out_dir, block[:adapter].downcase))
          end
          0
        end

        # @param view [Deployment] the deployment as one target sees it
        # @return [void] writes the files the target projects into `out_dir`
        def emit(view, root, out_dir)
          write(project(target_key(view.settings, view.world_file, view.domain), view, root), out_dir)
        end

        # @param block [Hash] one declared `deployed_to` block
        # @return [Deployment] the deployment as that target sees it: its settings, name and world
        def for_target(deployment, block)
          settings = tenant_settings(block, deployment.options, File.basename(deployment.domain))
          deployment.dup.tap do |view|
            view.world = Targets::TargetWorld.new(deployment.world, block)
            view.settings = settings
            view.infra_name = settings[:stack_name] || File.basename(deployment.domain)
          end
        end
      end
    end
  end
end
