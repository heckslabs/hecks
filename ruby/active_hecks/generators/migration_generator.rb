# ActiveHecks::MigrationGenerator
#
# Rails generator that produces SQL migration files from domain changes.
# Compares the current domain against the saved snapshot using DomainDiff
# and writes incremental SQL to db/hecks_migrate/ (separate from ActiveRecord).
#
#   rails generate active_hecks:migration
#
require "rails/generators"

module ActiveHecks
  class MigrationGenerator < ::Rails::Generators::Base
    desc "Generate Hecks SQL migrations from domain changes"

    def generate_migration
      config = ::Hecks.configuration
      unless config&.domain_obj
        say "Hecks is not configured. Add Hecks.configure in an initializer.", :red
        return
      end

      domain = config.domain_obj
      snapshot_path = ::Rails.root.join(Hecks::Migrations::DomainSnapshot::DEFAULT_PATH).to_s
      old_domain = Hecks::Migrations::DomainSnapshot.load(path: snapshot_path)

      changes = Hecks::Migrations::DomainDiff.call(old_domain, domain)

      if changes.empty?
        say "Domain is up to date — no migrations needed.", :green
        return
      end

      unless Hecks::Migrations::MigrationStrategy.for(:sql)
        Hecks::Migrations::MigrationStrategy.register(:sql, Hecks::Migrations::Strategies::SqlStrategy)
      end

      files = Hecks::Migrations::MigrationStrategy.run_all(changes, output_dir: ::Rails.root.to_s)

      files.each { |f| say "Generated #{f}", :green }

      Hecks::Migrations::DomainSnapshot.save(domain, path: snapshot_path)
      say "Saved domain snapshot to #{snapshot_path}", :green
    end
  end
end
