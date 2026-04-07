# ActiveHecks::Railtie
#
# Rails integration hook. Boots the Hecks application container after
# initializers load, and provides rake tasks for migration generation
# and execution. All Rails-specific behavior lives here under ActiveHecks,
# keeping the core Hecks namespace free of Rails concerns.
#
# Loaded automatically when Rails is detected:
#
#   require "active_hecks/railtie" if defined?(::Rails::Railtie)
#
# Rake tasks:
#   rake hecks:generate:migrations  — generate SQL from domain changes
#   rake hecks:db:migrate           — run pending Hecks SQL migrations
#
module ActiveHecks
  class Railtie < ::Rails::Railtie
    generators do
      require "active_hecks/generators/init_generator"
      require "active_hecks/generators/migration_generator"
    end

    initializer "active_hecks.setup", after: :load_config_initializers do
      if Hecks.configuration
        Hecks.configuration.boot!
      end
    end

    rake_tasks do
      namespace :hecks do
        desc "Generate Hecks SQL migrations from domain changes"
        task "generate:migrations" => :environment do
          config = Hecks.configuration
          unless config&.domain_obj
            puts "Hecks is not configured."
            next
          end

          domain = config.domain_obj
          snapshot_path = ::Rails.root.join(Hecks::Migrations::DomainSnapshot::DEFAULT_PATH).to_s
          old_domain = Hecks::Migrations::DomainSnapshot.load(path: snapshot_path)
          changes = Hecks::Migrations::DomainDiff.call(old_domain, domain)

          if changes.empty?
            puts "Domain is up to date — no migrations needed."
            next
          end

          unless Hecks::Migrations::MigrationStrategy.for(:sql)
            Hecks::Migrations::MigrationStrategy.register(:sql, Hecks::Migrations::Strategies::SqlStrategy)
          end
          files = Hecks::Migrations::MigrationStrategy.run_all(changes, output_dir: ::Rails.root.to_s)
          files.each { |f| puts "Generated #{f}" }

          Hecks::Migrations::DomainSnapshot.save(domain, path: snapshot_path)
          puts "Saved domain snapshot to #{snapshot_path}"
        end

        desc "Run pending Hecks SQL migrations"
        task "db:migrate" => :environment do
          connection = hecks_connection
          runner = Hecks::Migrations::MigrationRunner.new(
            connection: connection,
            migration_dir: ::Rails.root.join("db/hecks_migrate").to_s
          )
          applied = runner.run_all

          if applied.empty?
            puts "No pending migrations."
          else
            applied.each { |f| puts "Applied #{f}" }
          end
        end
      end

      def hecks_connection
        config = Hecks.configuration
        db = config&.instance_variable_get(:@db)
        return db if db # Sequel::Database — responds to #execute and #transaction

        ActiveRecord::Base.connection
      end
    end
  end
end
