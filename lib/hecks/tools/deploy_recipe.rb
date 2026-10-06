# frozen_string_literal: true

require "hecks"
require "fileutils"
require "optparse"
require_relative "../tools"
require_relative "deploy_recipe/worlds"
require_relative "deploy_recipe/targets"

module Hecks
  module Tools
    # The AWS deployment generator (ADR 0018): resolves a domain's declared `deployed_to(...)`
    # target and dispatches to the matching `Projector` export, writing the recipe (template,
    # scripts and Makefile) under `deploy/<stack>/` of the checkout.
    #
    #   hecks deploy recipe.project <domain> [--tenant=<slug>] [--schema=<name>]
    #       [--out=<dir>] [--environment=<name>]
    #
    # `--environment` layers an overlay `.world` file over the base one; a missing overlay is an
    # error. `--out` writes the recipe elsewhere, for a domain in a client's repo. `--tenant` and
    # `--schema` override the stack for shared-database hosting: `stack_name` is appended to, so
    # re-running with the same `--tenant` regenerates the same stack.
    module DeployRecipe
      USAGE = "usage: hecks deploy project <domain> [--tenant=<slug>] [--schema=<name>] " \
              "[--out=<dir>] [--environment=<name>]"

      # The directory `ports/` and `adapters/` live under, loaded into every domain's registry.
      LIB_HECKS = File.expand_path("..", __dir__)

      # What the flags asked for.
      Options = Struct.new(:tenant, :out, :environment)

      # What the generator resolved about a domain: its directory, the flags, the `.world` file and
      # its declaration, the `deployed_to` settings, the stack's name, the registry and the chapter.
      Deployment = Struct.new(:domain, :options, :world_file, :world, :settings, :infra_name, :registry, :chapter)

      extend Worlds
      extend Targets

      module_function

      # Generates the recipe and prints each file written.
      #
      # @param argv [Array<String>] the domain directory, then the flags
      # @param root [String] the checkout whose `deploy/` receives the recipe unless `--out` says
      #   otherwise
      # @return [Integer] 0
      # @raise [SystemExit] with the reason on stderr when the domain or its `.world` cannot
      #   generate
      def main(argv, root: Tools::ROOT)
        argv = argv.dup
        options = parse(argv)
        domain = argv.shift or abort USAGE

        deployment = resolve(domain, options)
        out_dir = options.out ? File.expand_path(options.out) : File.join(root, "deploy", deployment.infra_name)
        target = target_key(deployment.settings, deployment.world_file, domain)
        write(project(target, deployment, root), out_dir)
        0
      end

      # @param argv [Array<String>] the arguments; the flags are removed from it
      # @return [Options] the flags, with `tenant` a hash of `tenant` and `schema`
      # @raise [SystemExit] when `--schema` has no `--tenant`
      def parse(argv)
        options = Options.new({}, nil, nil)
        option_parser(options).parse!(argv)

        if options.tenant[:schema] && !options.tenant[:tenant]
          abort "--schema needs --tenant=<slug> — a schema override with no tenant to scope it to is meaningless"
        end
        options
      end

      # @return [OptionParser] the parser that fills `options` as flags are seen
      def option_parser(options)
        OptionParser.new do |parser|
          parser.on("--tenant=SLUG") { |v| options.tenant[:tenant] = v }
          parser.on("--schema=NAME") { |v| options.tenant[:schema] = v }
          parser.on("--out=DIR") { |v| options.out = v }
          parser.on("--environment=NAME") { |v| options.environment = v }
        end
      end

      # @param domain [String] the domain directory
      # @param options [Options] the flags
      # @return [Deployment] the world, settings, registry and chapter the recipe is projected from
      # @raise [SystemExit] when the domain or its `.world` cannot generate
      def resolve(domain, options)
        world_file = world_file_for(domain)
        basename = File.basename(world_file, ".world")
        world = load_world(world_file, domain, options.environment)
        settings = tenant_settings(world.for_verb("deployed_to"), options, File.basename(domain))
        registry = cross_domain_registry(domain, basename)
        Deployment.new(domain, options, world_file, world, settings, settings[:stack_name] || File.basename(domain),
                       registry, chapter_for(registry, world, world_file, basename))
      end

      # @return [Object] the chapter the world names
      # @raise [SystemExit] when the registry holds none
      def chapter_for(registry, world, world_file, bluebook_basename)
        registry.bluebook(world.domain) or
          abort "#{world_file} declares no #{world.domain} chapter — #{bluebook_basename}.bluebook's own " \
                "Hecks.bluebook name has to match world.domain."
      end

      # `Lambda` and `Fargate` raise `ArgumentError` for a domain's own deploy conflicts; it is
      # caught here so the message reaches stderr with a failing exit code instead of a backtrace.
      #
      # @param target [Symbol] the projector export
      # @param deployment [Deployment] what the generator resolved about the domain
      # @param root [String] the checkout
      # @return [Hash{String => String}] the files to write
      # @raise [SystemExit] when the domain's own settings conflict
      def project(target, deployment, root)
        artifact = Hecks::Projector.call(target, bluebook: deployment.chapter,
                                                 options: projector_options(deployment, root), world: deployment.world)
        # Only when the domain declared `smoke true`; otherwise nothing is added.
        artifact.merge(Hecks::Projections::Deploy::Smoke.files(deployment.settings, stack_name: deployment.infra_name))
      rescue ArgumentError => e
        abort e.message
      end

      def projector_options(deployment, root)
        {
          tenant:                deployment.options.tenant,
          domain_dir:            deployment.domain,
          root:                  root,
          world_file:            deployment.world_file,
          cross_domain_registry: deployment.registry
        }
      end

      # Writes the files, and prints where the recipe deploys from.
      #
      # @param artifact [Hash{String => String}] the files to write
      # @param out_dir [String] where they go
      # @return [void]
      def write(artifact, out_dir)
        Hecks::Projector.write(artifact, out_dir, as: :files).each do |path|
          File.chmod(0o755, path) if path.end_with?(".sh")
          puts "wrote #{path}"
        end
        puts
        puts "deploy from #{out_dir} — one command, nothing to type, nothing to remember:"
        puts "    make deploy"
      end
    end
  end
end
