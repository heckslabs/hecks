require "pg"
require_relative "postgres_probe"
require_relative "fenced_owner"

# A disposable local Postgres database for one spec file: created fresh before the group, scrubbed
# to an empty `public` schema before every example, and dropped after the group.
#
#   RSpec.describe "...", :io do
#     scratch_postgres SPEC_DB, fenced: true
#
# `fenced: true` hands the database to the non-superuser role PostgresEra boots as (see
# fenced_owner.rb). With no reachable Postgres the group skips; under `ENV["CI"]` the probe raises.
module ScratchPostgres
  def self.admin
    connection = PG.connect(dbname: "postgres")
    return connection unless block_given?

    yield connection
  ensure
    connection&.close if block_given?
  end

  # Drops and recreates each database, owned by the fenced role when `fenced`.
  def self.create(names, fenced: false)
    admin do |db|
      names.each do |name|
        db.exec("DROP DATABASE IF EXISTS #{name} WITH (FORCE)")
        db.exec("CREATE DATABASE #{name}")
      end
    end
    names.each { |name| FencedOwner.own!(name) } if fenced
  end

  def self.drop(names)
    admin { |db| names.each { |name| db.exec("DROP DATABASE IF EXISTS #{name} WITH (FORCE)") } }
  end

  # Empties each database's `public` schema, handing it back to the fenced role when `fenced`.
  def self.scrub(names, fenced: false)
    names.each do |name|
      db = PG.connect(dbname: name)
      db.exec("DROP SCHEMA public CASCADE")
      db.exec("CREATE SCHEMA public")
      db.close
      FencedOwner.own_public!(name) if fenced
    end
  end

  module Macros
    # Registers the create, scrub and drop hooks for the named databases on this example group.
    def scratch_postgres(*names, fenced: false)
      before(:all) do
        skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

        ScratchPostgres.create(names, fenced: fenced)
      end

      after(:all) { ScratchPostgres.drop(names) if PostgresProbe.available? }

      before { ScratchPostgres.scrub(names, fenced: fenced) }
    end
  end
end

RSpec.configure { |config| config.extend ScratchPostgres::Macros }
