# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module DeployRecipe
      # Finds and loads the `.world` file a domain deploys from, and the registry it boots into.
      module Worlds
        # The `.world` file named after the directory; failing that, the sole `*.world` file under
        # `<domain>/bluebook/`; failing that, the one named after the chapter the domain's hecksagon
        # attaches by name (`qa/` attaches QualityControl and also holds a Governance `.world`).
        # It picks by no other rule: guessing which is the domain is not this generator's call.
        #
        # @param domain [String] the domain directory
        # @return [String] the `.world` file
        # @raise [SystemExit] when there is none
        def world_file_for(domain)
          named = File.join(domain, "bluebook", "#{File.basename(domain)}.world")
          world_file = File.exist?(named) ? named : (sole_world_file(domain) || named)

          File.exist?(world_file) or
            abort "#{world_file} does not exist — a domain needs a .world file to declare " \
                  "deployed_to(\"AwsLambda\"), deployed_to(\"AwsFargate\"), deployed_to(\"AwsBox\"), " \
                  "deployed_to(\"AwsSharedDatabase\") or deployed_to(\"Vercel\")"
          world_file
        end

        # The snake-cased names of the chapters a domain's hecksagons attach by name
        # (`Hecks::Chapters.load!("QualityControl")`), which its `.world` and `.hecksagon` files
        # are named after.
        #
        # @param domain [String] the domain directory
        # @return [Array<String>] such as `["quality_control"]`
        def attached_stems(domain)
          Dir.glob(File.join(domain, "bluebook", "*.hecksagon"))
             .flat_map { |path| File.read(path).scan(/Chapters\.load!\(\s*"([^"]+)"\s*\)/).flatten }
             .map { |name| Hecks::Naming.snake(name) }.uniq
        end

        # @param world_file [String] the base `.world` file
        # @param domain [String] the domain directory
        # @param environment [String, nil] the overlay to layer over the base
        # @return [Object] the world's own declaration, named as the bluebook is
        # @raise [SystemExit] when an overlay is missing or the file declares no world
        def load_world(world_file, domain, environment)
          registry = Hecks::Runtime::Registry.new
          Hecks.with_registry(registry) do
            Kernel.load(world_file)
            load_overlay(domain, environment) if environment
          end

          registry.worlds.values.first or abort "#{world_file} declares no Hecks.world block at all"
        end

        # Applied before the stack's name is computed, so the output directory agrees with the stack
        # name `Lambda`/`Fargate` generate: they re-apply this same override against the `world` and
        # `tenant:` they are handed.
        #
        # @param deploy_settings [Hash] the world's `deployed_to` settings
        # @param options [Options] the flags
        # @param domain_name [String] the domain directory's name
        # @return [Hash] the settings, with the tenant appended to `stack_name` when there is one
        def tenant_settings(deploy_settings, options, domain_name)
          return deploy_settings unless options.tenant[:tenant]

          base = deploy_settings[:stack_name] || domain_name
          deploy_settings.merge(stack_name: "#{base}-#{options.tenant[:tenant]}")
        end

        # Loads the whole registry a domain boots with, not just its own `.bluebook`, because a
        # cross-domain invoke grant can live in any attached chapter. A domain with no bluebook of
        # its own (the QA ledger) gets its chapter from the hecksagon's `Chapters.load!`. `root:` is
        # required or `attaches ... from: :vendor` refuses with "needs a registry with a root to
        # vendor from".
        #
        # @param domain [String] the domain directory
        # @param bluebook_basename [String] the file name the domain's bluebook and hecksagon share
        # @return [Hecks::Runtime::Registry] the registry
        def cross_domain_registry(domain, bluebook_basename)
          registry = Hecks::Runtime::Registry.new(root: File.expand_path(domain))
          Hecks.with_registry(registry) { load_attached(domain, bluebook_basename) }
          registry
        end

        private

        # The sole `*.world` file, or the sole one named after an attached chapter.
        def sole_world_file(domain)
          candidates = Dir.glob(File.join(domain, "bluebook", "*.world"))
          named = candidates.select { |path| attached_stems(domain).include?(File.basename(path, ".world")) }
          pick = candidates.size == 1 ? candidates : named
          pick.first if pick.size == 1
        end

        def load_overlay(domain, environment)
          overlay_file = File.join(domain, "bluebook", "environments", "#{environment}.world")
          File.exist?(overlay_file) or
            abort "#{overlay_file} does not exist — --environment=#{environment} needs that overlay"
          Kernel.load(overlay_file)
        end

        # Loads the attached ports and adapters, then the domain's bluebook and hecksagon.
        def load_attached(domain, bluebook_basename)
          %w[ports/persistence.port ports/extraction.port adapters/driven/memory.adapter
             adapters/driven/prism.adapter].each { |file| Kernel.load(File.join(LIB_HECKS, file)) }
          %w[bluebook hecksagon].each do |extension|
            file = File.join(domain, "bluebook", "#{bluebook_basename}.#{extension}")
            Kernel.load(file) if File.exist?(file)
          end
        end
      end
    end
  end
end
