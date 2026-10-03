# frozen_string_literal: true

require "hecks"
require "fileutils"
require "optparse"
require_relative "../tools"

module Hecks
  module Tools
    # The AWS deployment generator (ADR 0018): resolves a domain's declared `deployed_to(...)`
    # target and dispatches to the matching `Projector` export, writing the recipe (template,
    # scripts and Makefile) under `deploy/<stack>/` of the checkout.
    #
    #   hecks deploy project <domain> [--tenant=<slug>] [--schema=<name>]
    #       [--out=<dir>] [--environment=<name>]
    #
    # `--environment` layers an overlay `.world` file over the base one; a missing overlay is an
    # error. `--out` writes the recipe elsewhere, for a domain in a client's repo. `--tenant` and
    # `--schema` override the stack for shared-database hosting: `stack_name` is appended to, so
    # re-running with the same `--tenant` regenerates the same stack.
    module DeployRecipe
      USAGE = "usage: hecks deploy project <domain> [--tenant=<slug>] [--schema=<name>] " \
              "[--out=<dir>] [--environment=<name>]"

      # What the flags asked for.
      Options = Struct.new(:tenant, :out, :environment)

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

        world_file = world_file_for(domain)
        bluebook_basename = File.basename(world_file, ".world")
        world = load_world(world_file, domain, options.environment)
        deploy_settings = tenant_settings(world.for_verb("deployed_to"), options, File.basename(domain))
        infra_name = deploy_settings[:stack_name] || File.basename(domain)

        registry = cross_domain_registry(domain, bluebook_basename)
        chapter = registry.bluebook(world.domain) or
          abort "#{world_file} declares no #{world.domain} chapter — #{bluebook_basename}.bluebook's own " \
                "Hecks.bluebook name has to match world.domain."

        out_dir = options.out ? File.expand_path(options.out) : File.join(root, "deploy", infra_name)
        artifact = project(target_key(deploy_settings, world_file, domain), chapter, world, registry,
                           deploy_settings: deploy_settings, infra_name: infra_name, options: options,
                           domain: domain, root: root, world_file: world_file)
        write(artifact, out_dir)
        0
      end

      # @param argv [Array<String>] the arguments; the flags are removed from it
      # @return [Options] the flags, with `tenant` a hash of `tenant` and `schema`
      # @raise [SystemExit] when `--schema` has no `--tenant`
      def parse(argv)
        options = Options.new({}, nil, nil)
        OptionParser.new do |parser|
          parser.on("--tenant=SLUG") { |v| options.tenant[:tenant] = v }
          parser.on("--schema=NAME") { |v| options.tenant[:schema] = v }
          parser.on("--out=DIR") { |v| options.out = v }
          parser.on("--environment=NAME") { |v| options.environment = v }
        end.parse!(argv)

        if options.tenant[:schema] && !options.tenant[:tenant]
          abort "--schema needs --tenant=<slug> — a schema override with no tenant to scope it to is meaningless"
        end
        options
      end

      # The `.world` file named after the directory; failing that, the sole `*.world` file under
      # `<domain>/bluebook/`; failing that, the one named after the chapter the domain's hecksagon
      # attaches by name (`qa/` attaches QualityControl and also holds a Governance `.world`).
      # It picks by no other rule: guessing which is the domain is not this generator's call.
      #
      # @param domain [String] the domain directory
      # @return [String] the `.world` file
      # @raise [SystemExit] when there is none
      def world_file_for(domain)
        world_file = File.join(domain, "bluebook", "#{File.basename(domain)}.world")
        unless File.exist?(world_file)
          candidates = Dir.glob(File.join(domain, "bluebook", "*.world"))
          named = candidates.select { |path| attached_stems(domain).include?(File.basename(path, ".world")) }
          pick = candidates.size == 1 ? candidates : named
          world_file = pick.first if pick.size == 1
        end

        File.exist?(world_file) or
          abort "#{world_file} does not exist — a domain needs a .world file to declare " \
                "deployed_to(\"AwsLambda\"), deployed_to(\"AwsFargate\") or deployed_to(\"AwsBox\")"
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
          if environment
            overlay_file = File.join(domain, "bluebook", "environments", "#{environment}.world")
            File.exist?(overlay_file) or
              abort "#{overlay_file} does not exist — --environment=#{environment} needs that overlay"
            Kernel.load(overlay_file)
          end
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
      # required or `uses_embryonaut_bluebook` refuses with "needs a registry with a root to
      # vendor from".
      #
      # @param domain [String] the domain directory
      # @param bluebook_basename [String] the file name the domain's bluebook and hecksagon share
      # @return [Hecks::Runtime::Registry] the registry
      def cross_domain_registry(domain, bluebook_basename)
        registry = Hecks::Runtime::Registry.new(root: File.expand_path(domain))
        lib_hecks = File.expand_path("..", __dir__)
        Hecks.with_registry(registry) do
          %w[ports/persistence.port ports/extraction.port adapters/driven/memory.adapter
             adapters/driven/prism.adapter].each { |file| Kernel.load(File.join(lib_hecks, file)) }
          bluebook_file = File.join(domain, "bluebook", "#{bluebook_basename}.bluebook")
          Kernel.load(bluebook_file) if File.exist?(bluebook_file)
          hecksagon_file = File.join(domain, "bluebook", "#{bluebook_basename}.hecksagon")
          Kernel.load(hecksagon_file) if File.exist?(hecksagon_file)
        end
        registry
      end

      # Each adapter maps to a registered `Projector` export (`needs_world: true`); this only finds
      # which one to call.
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
          abort <<~MSG
            #{world_file} declares no deployed_to("AwsLambda"), deployed_to("AwsFargate") or deployed_to("AwsBox") block. Add one, e.g.:

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

            then re-run hecks deploy project #{domain}.
          MSG
        end
      end

      # `Lambda` and `Fargate` raise `ArgumentError` for a domain's own deploy conflicts; it is
      # caught here so the message reaches stderr with a failing exit code instead of a backtrace.
      #
      # @param target [Symbol] the projector export
      # @param chapter [Object] the domain's chapter
      # @param world [Object] the domain's world
      # @param registry [Hecks::Runtime::Registry] the registry the chapter came from
      # @param context [Hash] `deploy_settings`, `infra_name`, `options`, `domain`, `root` and
      #   `world_file`
      # @return [Hash{String => String}] the files to write
      # @raise [SystemExit] when the domain's own settings conflict
      def project(target, chapter, world, registry, **context)
        artifact = Hecks::Projector.call(
          target,
          bluebook: chapter,
          options:  {
            tenant:                context[:options].tenant,
            domain_dir:            context[:domain],
            root:                  context[:root],
            world_file:            context[:world_file],
            cross_domain_registry: registry
          },
          world:    world
        )
        # Only when the domain declared `smoke true`; otherwise nothing is added.
        artifact.merge(Hecks::Projections::Deploy::Smoke.files(context[:deploy_settings],
                                                               stack_name: context[:infra_name]))
      rescue ArgumentError => e
        abort e.message
      end

      # Writes the files, and prints where the recipe deploys from.
      #
      # @param artifact [Hash{String => String}] the files to write
      # @param out_dir [String] where they go
      # @return [void]
      def write(artifact, out_dir)
        written = Hecks::Projector.write(artifact, out_dir, as: :files)

        written.each { |path| puts "wrote #{path}" }
        puts
        puts "deploy from #{out_dir} — one command, nothing to type, nothing to remember:"
        puts "    make deploy"
      end
    end
  end
end
