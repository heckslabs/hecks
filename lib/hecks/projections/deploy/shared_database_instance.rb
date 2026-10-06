require "json"
require_relative "../../projector"
require_relative "box/settings"

module Hecks
  module Projections
    module Deploy
      # The shared database target for `deployed_to("AwsSharedDatabase")`: one RDS Postgres instance
      # that several sites each keep a database on (ADR 0092). It renders the instance's stack
      # (`rds.yaml`), a `Makefile` that deploys it, and a README. A site's own world says
      # `shared_database "<this stack>"`, and its box generates the provisioning of its database.
      #
      # The stack's name is the world's `stack_name` exactly, with no prefix or suffix, because
      # every site names it by that string.
      module SharedDatabaseInstance
        extend Projector::Target

        projects_as :aws_shared_database, needs_world: true, emits: :files

        TEMPLATE_DIR = File.join(__dir__, "shared_database_instance", "templates").freeze

        # What the world leaves out resolves to these.
        DEFAULTS = { database_class: "db.t4g.small", storage_gb: 30, engine_version: "16", backup_days: 7 }.freeze

        # The checked settings the templates are filled from.
        Plan = Struct.new(:stack, :database_class, :storage_gb, :engine_version, :backup_days, keyword_init: true)

        module_function

        # @param bluebook [Bluebook::Behaviour::Chapter] the domain's own booted chapter
        # @param options [Hash] generation options; same shape as `Box.call`'s
        # @return [Hash{String => String}] the generated file contents, keyed by filename
        # @raise [ArgumentError] if the domain's deploy settings are invalid
        def call(bluebook:, options: {})
          world, _domain, world_file = options.values_at(:world, :domain_dir, :world_file)
          settings = world.for_verb("deployed_to")
          target = declare(world.domain, settings, world_file)
          render_all(resolve(settings, target))
        end

        # Validates the target through the Deploy bluebook's own `SharedDatabaseTarget.Declare`.
        #
        # @return [Object] the declared target aggregate
        # @raise [ArgumentError] when the bluebook refuses a value
        def declare(domain, settings, world_file)
          dispatcher = Hecks.boot(File.expand_path("../../deploy", __dir__))
          dispatcher.dispatch("Deploy::SharedDatabaseTarget.Declare", with: declare_arguments(domain, settings)).instance
        rescue *Hecks::Runtime::DOMAIN_REFUSALS => e
          raise ArgumentError, "#{world_file}'s deployed_to(\"AwsSharedDatabase\") is invalid: #{e.message}"
        end

        # @return [Hash{Symbol => Hash}] the `Declare` arguments, each `{ value: }`
        def declare_arguments(domain, settings)
          {
            domain: { value: domain }, region: { value: settings[:region] },
            database_class: { value: settings.fetch(:database_class, DEFAULTS[:database_class]) },
            storage_gb: { value: settings.fetch(:storage_gb, DEFAULTS[:storage_gb]) }
          }
        end

        # @param settings [Hash{Symbol => Object}] the world's `AwsSharedDatabase` settings
        # @param target [Object] the declared target, whose class and storage `Declare` has checked
        # @return [Plan] the checked settings
        # @raise [ArgumentError] when the stack name is missing or a setting is malformed
        def resolve(settings, target)
          Plan.new(stack: read_stack(settings), database_class: target.state[:database_class].value,
                   storage_gb: target.state[:storage_gb].value, engine_version: read_engine(settings),
                   backup_days: Box::Settings.integer(:backup_days, settings.fetch(:backup_days, DEFAULTS[:backup_days]), 1, 35))
        end

        # @return [String] the stack's name, which every site's `shared_database` repeats
        def read_stack(settings)
          stack = settings.fetch(:stack_name) do
            raise ArgumentError, "stack_name: the shared instance's stack, which every site names in shared_database"
          end
          Box::Settings.check(:stack_name, stack, Box::Settings::NAME)
        end

        # @return [String] the Postgres major (or major.minor) version
        def read_engine(settings)
          Box::Settings.check(:engine_version, settings.fetch(:engine_version, DEFAULTS[:engine_version]).to_s,
                              Box::Settings::ENGINE)
        end

        # @param plan [Plan] the checked settings
        # @return [Hash{String => String}] every generated file
        def render_all(plan)
          values = { "STACK" => plan.stack, "DB_CLASS" => plan.database_class, "DATABASE_CLASS" => plan.database_class,
                     "STORAGE_GB" => plan.storage_gb.to_s, "ENGINE_VERSION" => plan.engine_version,
                     "BACKUP_DAYS" => plan.backup_days.to_s }
          { "rds.yaml" => template("rds.yaml.tmpl", values), "Makefile" => template("Makefile.tmpl", values),
            "README.md" => template("README.md.tmpl", values) }
        end

        # Fills `@@NAME@@` markers.
        #
        # @param file [String] the template's name in `TEMPLATE_DIR`
        # @param values [Hash{String => String}] marker name => text
        # @return [String] the rendered file
        def template(file, values)
          values.reduce(File.read(File.join(TEMPLATE_DIR, file))) { |text, (marker, value)| text.gsub("@@#{marker}@@", value) }
        end
      end
    end
  end
end
