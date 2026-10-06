require "json"
require_relative "../../projector"
require_relative "vercel/settings"

module Hecks
  module Projections
    module Deploy
      # The Vercel deploy target for `deployed_to("Vercel")`: the domain's Rust host as one Vercel
      # function. It renders `vercel.json` (the function's size, region, the rewrite that sends every
      # path to it, crons), `.vercelignore`, `deploy-vercel.sh` and a `Makefile`.
      #
      # Persistence is the hecksagon's: the host reads `DATABASE_URL`, which the deploy script sets
      # from the caller's environment. This projection creates no database and holds no secret.
      module Vercel
        extend Projector::Target

        projects_as :vercel, needs_world: true, emits: :files

        # The function every request is rewritten to; its file is the host's Vercel entry point.
        FUNCTION = "api/host".freeze

        # Keeps only the release binaries in an uploaded `target/`, as Vercel's Rust guide advises.
        VERCELIGNORE = <<~IGNORE.freeze
          target/**
          !target/release
          !target/x86_64-unknown-linux-gnu/release/**
          !target/aarch64-unknown-linux-gnu/release/**
        IGNORE

        module_function

        # @param bluebook [Bluebook::Behaviour::Chapter] the domain's own booted chapter
        # @param options [Hash] generation options; same shape as `Box.call`'s
        # @return [Hash{String => String}] the generated file contents, keyed by filename
        # @raise [ArgumentError] if the domain's deploy settings are invalid
        def call(bluebook:, options: {})
          world, domain, world_file = options.values_at(:world, :domain_dir, :world_file)
          settings = tenant_settings(world.for_verb("deployed_to"), options[:tenant] || {}, File.basename(domain))
          target = declare(world.domain, settings, world_file)
          infra_name = (settings[:stack_name] || File.basename(domain)).to_s.tr("_", "-").downcase
          plan = Settings.resolve(deploy_settings: settings, target: target, infra_name: infra_name)
          render_all(plan)
        end

        # @return [Hash{Symbol => Object}] the settings with the `--tenant` suffix on the stack name
        def tenant_settings(settings, tenant, domain_name)
          return settings unless tenant[:tenant]

          settings.merge(stack_name: "#{settings[:stack_name] || domain_name}-#{tenant[:tenant]}")
        end

        # Validates the target through the Deploy bluebook's own `VercelTarget.Declare`.
        #
        # @return [Object] the declared target aggregate
        # @raise [ArgumentError] when the bluebook refuses a value
        def declare(domain, settings, world_file)
          dispatcher = Hecks.boot(File.expand_path("../../deploy", __dir__))
          dispatcher.dispatch("Deploy::VercelTarget.Declare", with: declare_arguments(domain, settings)).instance
        rescue *Hecks::Runtime::DOMAIN_REFUSALS => e
          raise ArgumentError, "#{world_file}'s deployed_to(\"Vercel\") is invalid: #{e.message}"
        end

        # @return [Hash{Symbol => Hash}] the `VercelTarget.Declare` arguments, each a `{ value: }`
        def declare_arguments(domain, settings)
          {
            domain: { value: domain }, region: { value: settings.fetch(:region, "iad1") },
            memory: { value: settings.fetch(:memory, 1024) },
            max_duration: { value: settings.fetch(:max_duration, 30) }
          }
        end

        # @param plan [Settings::Plan] the resolved settings
        # @return [Hash{String => String}] every generated file
        def render_all(plan)
          { "vercel.json" => vercel_json(plan), ".vercelignore" => VERCELIGNORE,
            "deploy-vercel.sh" => deploy_script(plan), "Makefile" => makefile(plan) }
        end

        # @param plan [Settings::Plan] the resolved settings
        # @return [String] `vercel.json`
        def vercel_json(plan)
          config = {
            "$schema"   => "https://openapi.vercel.sh/vercel.json",
            "functions" => { "#{FUNCTION}.rs" => { "memory" => plan.memory, "maxDuration" => plan.max_duration } },
            "regions"   => [plan.region],
            "rewrites"  => [{ "source" => "/(.*)", "destination" => "/#{FUNCTION}" }]
          }
          config["crons"] = plan.crons.map { |cron| cron.transform_keys(&:to_s) } if plan.crons.any?
          "#{JSON.pretty_generate(config)}\n"
        end

        # The script sets each named variable on the project from the caller's environment over
        # stdin, so no value is on a command line or in a file, then deploys to production.
        #
        # @param plan [Settings::Plan] the resolved settings
        # @return [String] `deploy-vercel.sh`
        def deploy_script(plan)
          scope = plan.scope ? " --scope #{plan.scope}" : ""
          sets = plan.env.map { |name| env_command(name, scope) }
          <<~SH
            #!/bin/bash
            # Deploys #{plan.project} to Vercel production. Needs VERCEL_TOKEN and each variable below in the
            # environment, e.g. `op run --env-file=.env.tpl -- make deploy`; no value is written to disk.
            set -euo pipefail
            cd "$(dirname "$0")"
            vercel link --yes --project #{plan.project}#{scope}
            #{sets.join("\n")}
            vercel deploy --prod --yes#{scope}
          SH
        end

        # @param name [String] a checked variable name
        # @param scope [String] the ` --scope team` flag, or empty
        # @return [String] the line that reads the variable and sets it on the project
        def env_command(name, scope)
          "printf '%s' \"${#{name}:?#{name} must be set in the environment}\" | " \
            "vercel env add #{name} production --sensitive --force --yes#{scope}"
        end

        # @param plan [Settings::Plan] the resolved settings
        # @return [String] the `Makefile`
        def makefile(plan)
          <<~MAKE
            # #{plan.project}: one Vercel function.
            #   make deploy   (needs VERCEL_TOKEN and #{plan.env.join(", ")} in the environment)
            .PHONY: deploy
            deploy:
            \t./deploy-vercel.sh
          MAKE
        end
      end
    end
  end
end
