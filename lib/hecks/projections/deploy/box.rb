require "json"
require_relative "../../projector"
require_relative "box/settings"
require_relative "box/hosting"
require_relative "box/roll_recipe"
require_relative "box/caddy"
require_relative "box/access"
require_relative "box/stack_yaml"
require_relative "box/compose"
require_relative "box/shared_database"
require_relative "box/roll_scripts"

module Hecks
  module Projections
    module Deploy
      # The AWS single-box deploy target for `deployed_to("AwsBox")`: one EC2 instance that runs the
      # domain's containers with Docker Compose behind Caddy, reading a plain RDS Postgres instance.
      # It renders two CloudFormation stacks (the database, the box), the proxy's `Caddyfile`, the
      # `services.json` compose is rendered from, and the scripts that roll the box.
      module Box
        extend Projector::Target
        extend Caddy
        extend Access
        extend StackYaml
        extend Compose
        extend SharedDatabase
        extend RollScripts

        projects_as :aws_box, needs_world: true, emits: :files

        TEMPLATE_DIR = File.join(__dir__, "box", "templates").freeze

        # Region suffixes of an Elastic address's public DNS name; us-east-1 is the only region with
        # the legacy `compute-1` form.
        LEGACY_COMPUTE_REGION = "us-east-1".freeze

        # The end of every Caddyfile: sites a rehearsal mounts under `caddy-extra`, such as a
        # loopback listener that adds the origin secret so a smoke test runs without the CDN. A
        # glob that matches nothing is not an error, so production, which mounts none, is unchanged.
        CADDY_EXTRA = "# Rehearsal-only sites are mounted here; nothing matches in production. Restart the proxy\n" \
                      "# after adding one: the admin API is off, so a reload cannot reach it.\n" \
                      "import /etc/caddy/extra/*\n".freeze

        # The `smoke-after-deploy` recipe: the smoke runs as `smoke_run.run`, which finds
        # `smoke-after-deploy.sh` beside the Makefile and records how it ended in the Hecks
        # database. When that database cannot be opened the command never starts, so the recipe
        # runs the script itself, states the database error apart from the smoke's result, and
        # exits non-zero (24 when the smoke passed).
        SMOKE_RECIPE = [
          "@err=$$(mktemp); \\",
          '$(HECKS) deploy smoke_run.run project="$(CURDIR)" --wait $(if $(TASKDEF),taskdef=$(TASKDEF)) 2>"$$err"; rc=$$?; \\',
          'if [ $$rc -ne 0 ] && grep -q \'^cannot open Hecks\' "$$err"; then \\',
          '  echo "==> the deploy record was NOT written: $$(grep -m1 \'^cannot open Hecks\' "$$err")" >&2; \\',
          '  echo "    one-time setup on this machine: a database AND a non-superuser role that owns it" >&2; \\',
          '  echo "    (a superuser skips the era write-fence, so createdb alone fails), then set" >&2; \\',
          '  echo "    HECKS_DATABASE=postgres://<role>@localhost/<db>" >&2; \\',
          '  echo "    running the smoke anyway so its result is not lost" >&2; \\',
          '  rm -f "$$err"; TASKDEF="$(TASKDEF)" bash ./smoke-after-deploy.sh; rc=$$?; \\',
          '  echo "==> smoke exit $$rc. The deploy record was NOT written: the database is unavailable (see above)." >&2; \\',
          "  [ $$rc -ne 0 ] || rc=24; exit $$rc; \\",
          "fi; \\",
          'cat "$$err" >&2; rm -f "$$err"; exit $$rc'
        ].join("\n\t").freeze

        module_function

        # Generates `rds.yaml`, `box.yaml`, `Caddyfile`, `services.json`, `render-compose.sh`,
        # `fetch-secrets.sh`, `deploy-box.sh` and a `Makefile`, and for a world that declares a
        # `migration`, `restore-to-rds.sh`, `verify-copy.sh` and `MIGRATION.md`.
        #
        # @param bluebook [Bluebook::Behaviour::Chapter] the domain's own booted chapter
        # @param options [Hash] generation options; same shape as `Fargate.call`'s
        # @return [Hash{String => String}] the generated file contents, keyed by filename
        # @raise [ArgumentError] if the domain's deploy settings are invalid or conflict
        def call(bluebook:, options: {})
          world, domain, world_file = options.values_at(:world, :domain_dir, :world_file)
          settings = tenant_settings(world.for_verb("deployed_to"), options[:tenant] || {}, File.basename(domain))
          target = declare(world.domain, settings, world_file)
          plan = Settings.resolve(deploy_settings: settings, target: target, infra_name: infra_name_of(settings, domain))
          render_all(plan, target.state[:region].value)
        end

        # @param settings [Hash{Symbol => Object}] the world's `deployed_to` settings
        # @param domain [String] the domain directory
        # @return [String] the stack name as a lowercase, hyphenated resource name
        def infra_name_of(settings, domain)
          (settings[:stack_name] || File.basename(domain)).to_s.tr("_", "-").downcase
        end

        # Applies the `--tenant` suffix to the stack name, as `Fargate.call` does.
        #
        # @param settings [Hash{Symbol => Object}] the world's `deployed_to` settings
        # @param tenant [Hash] the `--tenant` and `--schema` options
        # @param domain_name [String] the domain directory's name
        # @return [Hash{Symbol => Object}] the settings with the tenant's stack name
        def tenant_settings(settings, tenant, domain_name)
          return settings unless tenant[:tenant]

          settings.merge(stack_name: "#{settings[:stack_name] || domain_name}-#{tenant[:tenant]}")
        end

        # Validates the target through the Deploy bluebook's own `BoxTarget.Declare`.
        #
        # @param domain [String] the world's domain name
        # @param settings [Hash{Symbol => Object}] the world's `deployed_to` settings
        # @param world_file [String] the `.world` file, named in a refusal
        # @return [Object] the declared target aggregate
        # @raise [ArgumentError] when the bluebook refuses a value
        def declare(domain, settings, world_file)
          dispatcher = Hecks.boot(File.expand_path("../../deploy", __dir__))
          dispatcher.dispatch("Deploy::BoxTarget.Declare", with: declare_arguments(domain, settings)).instance
        rescue *Hecks::Runtime::DOMAIN_REFUSALS => e
          raise ArgumentError, "#{world_file}'s deployed_to(\"AwsBox\") is invalid: #{e.message}"
        end

        # @param domain [String] the world's domain name
        # @param settings [Hash{Symbol => Object}] the world's `deployed_to` settings
        # @return [Hash{Symbol => Hash}] the `BoxTarget.Declare` arguments, each a `{ value: }`
        def declare_arguments(domain, settings)
          {
            domain: { value: domain }, region: { value: settings[:region] },
            instance_type: { value: settings.fetch(:instance_type, "t4g.medium") },
            volume_gb: { value: settings.fetch(:volume_gb, 30) },
            database_class: { value: settings.fetch(:database_class, "db.t4g.small") },
            storage_gb: { value: settings.fetch(:storage_gb, 20) }
          }
        end

        # @param plan [Settings::Plan] the resolved settings
        # @param region [String] the validated region
        # @return [Hash{String => String}] every generated file
        def render_all(plan, region)
          {
            "box.yaml" => box_yaml(plan, region),
            "Caddyfile" => caddyfile(plan), "services.json" => services_json(plan),
            "render-compose.sh" => render_compose_sh(plan, region),
            "fetch-secrets.sh" => File.read(File.join(TEMPLATE_DIR, "fetch-secrets.sh")),
            "deploy-box.sh" => deploy_box_sh(plan, region),
            "Makefile" => makefile(plan)
          }.merge(database_files(plan)).merge(migration_files(plan))
            .then { |files| Hosting.extend_files(files, plan: plan, region: region) }
        end

        # @param plan [Settings::Plan] the resolved settings
        # @return [Hash{String => String}] the database stack, or for a database on a shared
        #   instance the script that provisions it; the shared stack is not this site's to generate
        def database_files(plan)
          return { "rds.yaml" => rds_yaml(plan) } unless plan.shared?

          { "provision-database.sh" => provision_database_sh(plan) }
        end

        # Fills `@@NAME@@` markers. A marker alone on its line is replaced together with the line,
        # so an empty value leaves no blank line behind; one inside a line is replaced in place.
        #
        # @param file [String] the template file's name in `TEMPLATE_DIR`
        # @param values [Hash{String => String}] marker name => text
        # @return [String] the rendered file
        def template(file, values)
          values.reduce(File.read(File.join(TEMPLATE_DIR, file))) do |text, (marker, value)|
            own_line = /^@@#{marker}@@\n/
            if text.match?(own_line)
              text.sub(own_line) { value.empty? || value.end_with?("\n") ? value : "#{value}\n" }
            else
              text.gsub("@@#{marker}@@") { value }
            end
          end
        end
      end
    end
  end
end
