# frozen_string_literal: true

require "fileutils"
require_relative "../../hecks"
require_relative "../three_zero"

module Hecks
  module CLI
    # The command behind `bin/project_deploy` and `hecks deploy project` (ADR 0018): resolves a
    # domain's declared `deployed_to(...)` target and renders the deploy recipe its Projector
    # export produces.
    #
    # The domain is read from `<domain>/bluebook/<name>.world`. A tenant or schema override
    # rewrites the deploy settings before any name is computed, and `environment` layers an
    # overlay world over the base one (a missing overlay is a refusal, never a silent no-op).
    # Every refusal is a `Refusal` whose message is the sentence a person reads.
    module ProjectDeploy
      # A request the generator cannot carry out; the message says what to change.
      class Refusal < StandardError; end

      # The hecks checkout or gem root the rendered recipes point back at.
      ROOT = File.expand_path("../../..", __dir__).freeze

      # The adapters a domain can declare, and the export that renders each.
      TARGETS = { "AwsLambda" => :aws_lambda, "AwsFargate" => :aws_fargate }.freeze

      # What a rendering wrote: the directory, and every path in it.
      Rendered = Struct.new(:out_dir, :written)

      # A domain's world file, the world it declares and its deploy settings.
      Found = Struct.new(:file, :world, :basename, :settings)

      module_function

      # Renders and writes a domain's deploy recipe.
      #
      # @param domain [String] the domain directory (holding `bluebook/`)
      # @param tenant [String, nil] a per-tenant override for shared-database hosting
      # @param schema [String, nil] the tenant's schema; needs `tenant`
      # @param out [String, nil] where to write; `<out_root>/deploy/<stack>` when absent
      # @param environment [String, nil] an overlay world under `bluebook/environments/`
      # @param root [String] the hecks root the recipes reference
      # @param out_root [String] the directory the default output goes under
      # @return [Rendered] the directory written to, and the paths written
      # @raise [Refusal] if the domain declares no deploy target, or the request contradicts itself
      def call(domain:, tenant: nil, schema: nil, out: nil, environment: nil, root: ROOT, out_root: root)
        if schema && !tenant
          raise Refusal, "--schema needs --tenant=<slug> — a schema override with no tenant to scope it to is meaningless"
        end

        found = world_for(domain, environment)
        settings = tenant_settings(found.settings, domain, tenant)
        infra_name = settings[:stack_name] || File.basename(domain)
        out_dir = out ? File.expand_path(out) : File.join(out_root, "deploy", infra_name)
        artifact = render(found, settings, domain, root, { tenant: tenant, schema: schema }.compact, infra_name)
        Rendered.new(out_dir, Projector.write(ThreeZero.annotate_deploy_files(artifact), out_dir, as: :files))
      end

      # The adapter a domain's world declares, without rendering anything.
      #
      # @param domain [String] the domain directory
      # @param environment [String, nil] an overlay world under `bluebook/environments/`
      # @return [String, nil] `"AwsLambda"`, `"AwsFargate"`, another adapter's name, or nil when
      #   the world declares no `deployed_to`
      # @raise [Refusal] if the domain has no world file, or the overlay is missing
      def target(domain:, environment: nil)
        world_for(domain, environment).settings[:adapter]
      end

      # @param domain [String] the domain directory
      # @param environment [String, nil] an overlay world under `bluebook/environments/`
      # @return [Found] the world file read, and what it declares
      # @raise [Refusal] if the domain has no world file, or the overlay is missing
      def world_for(domain, environment)
        file = world_file(domain)
        registry = Runtime::Registry.new
        Hecks.with_registry(registry) do
          Kernel.load(file)
          layer_overlay(domain, environment) if environment
        end
        world = registry.worlds.values.first or raise Refusal, "#{file} declares no Hecks.world block at all"
        Found.new(file, world, File.basename(file, ".world"), world.for_verb("deployed_to"))
      end

      # The world file named for the directory, or the only one there when it is named otherwise;
      # never picked from several, since which is the domain's is not this generator's call.
      def world_file(domain)
        file = File.join(domain, "bluebook", "#{File.basename(domain)}.world")
        candidates = Dir.glob(File.join(domain, "bluebook", "*.world"))
        file = candidates.first if !File.exist?(file) && candidates.size == 1
        return file if File.exist?(file)

        raise Refusal, "#{file} does not exist — a domain needs a .world file to declare " \
                       "deployed_to(\"AwsLambda\") or deployed_to(\"AwsFargate\")"
      end

      def layer_overlay(domain, environment)
        overlay = File.join(domain, "bluebook", "environments", "#{environment}.world")
        raise Refusal, "#{overlay} does not exist — --environment=#{environment} needs that overlay" unless File.exist?(overlay)

        Kernel.load(overlay)
      end

      # Applied before the stack name is computed, so the output directory agrees with the name
      # Lambda and Fargate generate; re-running with the same tenant regenerates the same stack.
      def tenant_settings(settings, domain, tenant)
        return settings unless tenant

        settings.merge(stack_name: "#{settings[:stack_name] || File.basename(domain)}-#{tenant}")
      end

      # Loads the whole registry a domain boots with, not just its own `.bluebook`: a
      # cross-domain invoke grant can live in any attached chapter.
      def cross_domain_registry(domain, basename)
        lib = File.expand_path("..", __dir__)
        registry = Runtime::Registry.new(root: File.expand_path(domain))
        Hecks.with_registry(registry) do
          %w[ports/persistence.port ports/extraction.port adapters/driven/memory.adapter
             adapters/driven/prism.adapter].each { |file| Kernel.load(File.join(lib, file)) }
          Kernel.load(File.join(domain, "bluebook", "#{basename}.bluebook"))
          hecksagon = File.join(domain, "bluebook", "#{basename}.hecksagon")
          Kernel.load(hecksagon) if File.exist?(hecksagon)
        end
        registry
      end

      def render(found, settings, domain, root, tenant, infra_name)
        registry = cross_domain_registry(domain, found.basename)
        chapter = registry.bluebook(found.world.domain) or
          raise Refusal, "#{found.file} declares no #{found.world.domain} chapter — " \
                         "#{found.basename}.bluebook's own Hecks.bluebook name has to match world.domain."
        key = TARGETS[settings[:adapter]] or raise Refusal, no_target(found.file, domain)

        artifact = Projector.call(key, bluebook: chapter, world: found.world,
                                       options: { tenant: tenant, domain_dir: domain, root: root,
                                                  world_file: found.file, cross_domain_registry: registry })
        artifact.merge(Projections::Deploy::Smoke.files(settings, stack_name: infra_name))
      rescue ArgumentError => e
        raise Refusal, e.message
      end

      def no_target(file, domain)
        <<~MSG
          #{file} declares no deployed_to("AwsLambda") or deployed_to("AwsFargate") block. Add one, e.g.:

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

          then re-run the deploy for #{domain}.
        MSG
      end
    end
  end
end
