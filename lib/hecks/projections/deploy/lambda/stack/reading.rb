module Hecks
  module Projections
    module Deploy
      module Lambda
        class Stack
          # Reads a stack's facts from the options, the world and the files beside it. Included into
          # `Stack`; each step is one move of its constructor.
          module Reading
            private

            def read_options(options)
              world = options.fetch(:world)
              @domain = options.fetch(:domain_dir)
              @root = options.fetch(:root)
              @world_file = options.fetch(:world_file)
              @registry = options.fetch(:cross_domain_registry)
              @tenant_options = options[:tenant] || {}
              @domain_name = File.basename(domain)
              @declared_domain_name = world.domain
              @deploy_settings = world.for_verb("deployed_to")
            end

            # Structural-only load (no `run_boot_gates!`/live persistence adapter) populates
            # `registry.pending_privacy_markings` for pii detection without requiring a real
            # Postgres connection to generate a template.
            #
            # Only `category: "pii"` triggers CloudFront/WAF provisioning; other marking categories
            # (e.g. "phi") stay a Governance/redaction concern.
            def detect_pii
              pii_registry = Hecks::Runtime::Registry.new(root: File.expand_path(domain))
              Hecks.with_registry(pii_registry) { load_structure(File.join(domain, "bluebook")) }
              @pii_detected = pii_registry.pending_privacy_markings.any? { |marking| marking[:category].to_s == "pii" }
            end

            def load_structure(bluebook_dir)
              bootstrap = Hecks::Ports::Loading.bootstrap
              bootstrap.load_library
              bootstrap.load_project(bootstrap.shared_root(nil, bluebook_dir))
              bootstrap.load_bluebooks(bluebook_dir)
              Dir.glob(File.join(bluebook_dir, "*.hecksagon")).each { |file| Kernel.load(file) }
            end

            # Applied before infra_name/hecks_schema below, so both read the override the same way
            # they read any other `deployed_to` setting.
            def read_names
              apply_tenant
              # Every AWS-facing name (stack, logical ids, S3 prefixes, secrets) reads `infra_name`,
              # not `domain_name`, so a `stack_name` override survives a later `formerly_known_as`
              # rename of the declared identity without renaming (and disconnecting from) the live
              # AWS stack.
              @infra_name = deploy_settings[:stack_name] || domain_name
              # RDS's own DBName/DatabaseName parameter refuses non-alphanumeric characters; every
              # downstream consumer (Environment vars, Makefile shell commands) has to read the same
              # sanitized spelling.
              @db_name = infra_name.gsub(/[^a-zA-Z0-9]/, "")
            end

            def apply_tenant
              return unless @tenant_options[:tenant]

              base_stack_name = deploy_settings[:stack_name] || domain_name
              schema = @tenant_options.key?(:schema) ? @tenant_options[:schema] : @tenant_options[:tenant]
              @deploy_settings = deploy_settings.merge(stack_name: "#{base_stack_name}-#{@tenant_options[:tenant]}",
                                                       schema:     schema)
            end

            # Dispatches into LambdaTarget.Declare's given/invariant machinery for named,
            # corpus-testable refusals (memory/timeout checked as real Integers against Lambda's
            # 128-10240 MB / 900s ceilings).
            def declare_target
              dispatcher = Hecks.boot(File.expand_path("../../../../deploy", __dir__))
              target = dispatcher.dispatch("Deploy::LambdaTarget.Declare", with: declare_arguments).instance
              read_target(target.state)
            rescue *Hecks::Runtime::DOMAIN_REFUSALS => e
              raise ArgumentError, "#{world_file}'s deployed_to(\"AwsLambda\") is invalid: #{e.message}"
            end

            def declare_arguments
              {
                domain:   { value: declared_domain_name },
                region:   { value: deploy_settings[:region] },
                memory:   { value: deploy_settings.fetch(:memory, 512) },
                timeout:  { value: deploy_settings.fetch(:timeout, 10) },
                database: { value: deploy_settings.fetch(:database, "Postgres") },
                web:      { value: deploy_settings.fetch(:web, "None") },
                **declared_strings
              }
            end

            def declared_strings
              %i[dispatch handler_module secret_env].select { |key| deploy_settings.key?(key) }
                                                    .to_h { |key| [key, { value: deploy_settings[key].to_s }] }
            end

            def read_target(state)
              read_dispatch
              @region = state[:region].value
              @memory = state[:memory].value
              @timeout = state[:timeout].value
              @aurora = state[:database].value == "Aurora"
              @shared = state[:database].value == "Shared"
              @rust_web = state[:web].value == "Rust"
            end

            def read_dispatch
              # `dispatch "None"` skips generating a rust/host dispatch Lambda for a domain with no
              # `.bluebook` command surface to dispatch through (e.g. QualityControl's GitHub
              # webhook, dispatching straight into Ruby); such a domain's WebFunction becomes its
              # only Lambda.
              @dispatch_none = deploy_settings[:dispatch].to_s == "None"
              # Names the env var WebFunction's `lambda_handler.rb` finds the fetched secret's
              # plaintext under, once it resolves `#{secret_env}_ARN`.
              @webhook_secret_env = deploy_settings[:secret_env]
              # The module name `lambda_handler.rb` actually defines; named here since
              # `dispatch "None"` domains may each pick their own.
              @webhook_handler_module = deploy_settings.fetch(:handler_module, "WebLambdaHandler")
              read_cross_domain_targets
            end

            # Scans every loaded chapter, not just this domain's own: an `attaches`-attached chapter
            # can itself declare a cross-domain policy, including one nested inside
            # `aggregate "X" do ... end`.
            def read_cross_domain_targets
              @cross_domain_targets = @registry.bluebooks.flat_map do |_name, bluebook|
                bluebook.policies.select(&:target_domain).map(&:target_domain)
              end.uniq.sort
            end

            # Shared mode provisions no RDS/VPC of its own; it borrows another already-deployed
            # domain's instance, isolated by Postgres schema.
            def read_owner
              read_geo_restriction
              read_shared_owner if shared
              @hecks_schema = shared ? infra_name : deploy_settings[:schema]
            end

            # Read off `deploy_settings` directly, not the declared target: these two are optional
            # and pii-only, unlike every always-validated target state.
            def read_geo_restriction
              @geo_restriction_type = deploy_settings[:geo_restriction] || "none"
              @geo_restriction_countries = deploy_settings[:geo_restriction_countries] || []
            end

            def read_shared_owner
              @owner_domain_name = deploy_settings[:owner] or raise ArgumentError, missing_owner_message
              # `owner_stack` is the escape hatch for an owner whose live stack name predates the
              # "hecks-<lowercase name>" convention below.
              @owner_stack_name = deploy_settings[:owner_stack] || "hecks-#{owner_domain_name.downcase}"
              @owner_db_name = owner_domain_name.downcase
            end

            def missing_owner_message
              TextTemplate.render_from("lambda/missing_owner.tmpl", self)
            end

            # The "hecks-" half of this domain's own stack name is overridable for a live stack that
            # predates the convention. Everything downstream (FunctionNames, OAuth secret, bastion
            # stack, samconfig) reads `stack_name`; `infra_name` (logical ids, DB name) is
            # untouched.
            def derive_ids
              @logical_id = "#{infra_name.split(/[_-]/).map(&:capitalize).join}Function"
              @stack_prefix = deploy_settings[:stack_prefix] || "hecks"
              @stack_name = "#{stack_prefix}-#{infra_name}"
            end
          end
        end
      end
    end
  end
end
