require_relative "../text_template"
require_relative "settings"
require_relative "stack/readers"
require_relative "stack/blocks"
require_relative "stack/recipes"

module Hecks
  module Projections
    module Deploy
      module Fargate
        # Everything the Fargate generator knows about one stack, read and checked once from the
        # world: the target's declared sizes, the plan, the owner a Shared database borrows. The
        # templates under `templates/fargate/` read each marker's value from the method of the same
        # name.
        class Stack
          include Readers
          include Blocks
          include Recipes

          attr_reader :domain, :root, :world_file, :domain_name, :declared_domain_name, :deploy_settings, :infra_name,
                      :db_name, :region, :cpu, :memory, :port, :web, :aurora, :shared, :google_oauth_present,
                      :owner_domain_name, :owner_stack_name, :owner_db_name, :hecks_schema, :logical_id,
                      :stack_prefix, :stack_name, :desired_count, :plan, :cross_domain_targets

          # @param options [Hash] the generation options `Fargate.call` receives
          # @raise [ArgumentError] if the domain's deploy settings are invalid or conflict
          def initialize(options)
            read_options(options)
            declare_target
            read_flags
            read_owner
            resolve_plan
          end

          private

          def read_options(options)
            world = options.fetch(:world)
            @domain = options.fetch(:domain_dir)
            @root = options.fetch(:root)
            @world_file = options.fetch(:world_file)
            registry = options.fetch(:cross_domain_registry)
            @domain_name = File.basename(domain)
            @declared_domain_name = world.domain
            @deploy_settings = tenant_settings(world.for_verb("deployed_to"), options[:tenant] || {})
            read_names(registry)
          end

          def read_names(registry)
            @infra_name = deploy_settings[:stack_name] || domain_name
            @db_name = infra_name.gsub(/[^a-zA-Z0-9]/, "")
            @cross_domain_targets = registry.bluebooks.flat_map do |_name, chapter|
              chapter.policies.select(&:target_domain).map(&:target_domain)
            end.uniq.sort
          end

          # Same tenant override `Lambda.call` applies; see that method's comment.
          def tenant_settings(settings, tenant)
            return settings unless tenant[:tenant]

            settings.merge(stack_name: "#{settings[:stack_name] || domain_name}-#{tenant[:tenant]}",
                           schema:     tenant.key?(:schema) ? tenant[:schema] : tenant[:tenant])
          end

          # Validated the same way `Lambda.call` validates its own target: `deploy.bluebook`'s own
          # `FargateTarget.Declare`, not a hand-checked `fetch(:cpu) { raise ... }` chain.
          def declare_target
            dispatcher = Hecks.boot(File.expand_path("../../../deploy", __dir__))
            target = dispatcher.dispatch("Deploy::FargateTarget.Declare", with: declare_arguments).instance
            read_target(target.state)
          rescue *Hecks::Runtime::DOMAIN_REFUSALS => e
            raise ArgumentError, "#{world_file}'s deployed_to(\"AwsFargate\") is invalid: #{e.message}"
          end

          def declare_arguments
            {
              domain:   { value: declared_domain_name },
              region:   { value: deploy_settings[:region] },
              cpu:      { value: deploy_settings.fetch(:cpu, 256) },
              memory:   { value: deploy_settings.fetch(:memory, 512) },
              database: { value: deploy_settings.fetch(:database, "Postgres") },
              web:      { value: deploy_settings.fetch(:web, "None") },
              port:     { value: deploy_settings.fetch(:port, 8080) }
            }
          end

          def read_target(state)
            @region = state[:region].value
            @cpu = state[:cpu].value
            @memory = state[:memory].value
            @port = state[:port].value
            @web = state[:web].value
            @aurora = state[:database].value == "Aurora"
            @shared = state[:database].value == "Shared"
          end

          # Same `.env.local` convention `Lambda` uses; `make sync-google-oauth` owns the secret's
          # lifecycle. Fargate only declares GOOGLE_OAUTH_SECRET_ID: the secret itself is never a
          # stack resource.
          def read_flags
            env_file = File.join(domain, ".env.local")
            @google_oauth_present = web == "Rust" && File.exist?(env_file) &&
                                    File.read(env_file).match?(/^GOOGLE_CLIENT_ID=\S/)
          end

          # Same "Shared" borrowing `Lambda.call` supports. `owner`/`owner_stack` stay plain
          # `deploy_settings` reads, never validated attributes: ownership is a deploy-time wiring
          # fact.
          def read_owner
            if shared
              @owner_domain_name = deploy_settings[:owner] or raise ArgumentError, missing_owner_message
              @owner_stack_name = deploy_settings[:owner_stack] || "hecks-#{owner_domain_name.downcase}"
              @owner_db_name = owner_domain_name.downcase
            end
            @hecks_schema = shared ? infra_name : deploy_settings[:schema]
          end

          def missing_owner_message
            TextTemplate.render_from("fargate/missing_owner.tmpl", self)
          end

          def derive_names
            @logical_id = "#{infra_name.split(/[_-]/).map(&:capitalize).join}Service"
            @stack_prefix = deploy_settings[:stack_prefix] || "hecks"
            @stack_name = "#{stack_prefix}-#{infra_name}"
            @desired_count = deploy_settings.fetch(:desired_count, 1)
          end

          # Every optional setting, checked; a world that sets none resolves to the derived ids and
          # names the generator has always used.
          def resolve_plan
            derive_names
            @plan = Settings.resolve(deploy_settings, plan_base)
          rescue ArgumentError => e
            raise ArgumentError, "#{world_file}'s deployed_to(\"AwsFargate\"): #{e.message}"
          end

          def plan_base
            { infra_name: infra_name, logical_id: logical_id, db_id: "#{logical_id.sub(/Service\z/, "")}Db",
              stack_name: stack_name, port: port, shared: shared }
          end
        end
      end
    end
  end
end
