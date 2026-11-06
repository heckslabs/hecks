#!/usr/bin/env ruby
# Rust's mint_harness holds a first era in a scratch database; Ruby reads it back. Prints Ruby's
# projection of the same bluebook beside what Ruby reads from the era Rust stored, with the held
# text blanked so only the stored projection can answer.
# usage: rust_mint_projection_matches_ruby.rb <mint_harness_binary>

require "pg"
$LOAD_PATH.unshift File.expand_path("../../../../lib", __dir__)
require "hecks"
require "hecks/ports/persistence/plugins/era"
require "json"
require "tempfile"
require "open3"
require "securerandom"

SOURCE = <<~BLUEBOOK.freeze
  Hecks.bluebook "Ledger" do
    aggregate "Account" do
      identified_by :kind
      attribute :cost, Money
      attribute :kind, Kind

      value_object "Money" do
        attribute :cents, Integer
      end

      value_object "Kind" do
        attribute :label, String
      end
    end
  end
BLUEBOOK

def load_registry
  registry = Hecks::Runtime::Registry.new
  loading = Hecks::Ports::Loading.bootstrap
  Hecks.with_registry(registry) do
    loading.load_library
    Kernel.eval(SOURCE, TOPLEVEL_BINDING, "rust_mint_projection.bluebook", 1)
  end
  registry
end

def scratch_database(db, owner)
  login = ENV["PGPASSWORD"] ? "LOGIN PASSWORD '#{ENV["PGPASSWORD"].gsub("'", "''")}'" : "LOGIN"
  admin = PG.connect(dbname: "postgres")
  admin.exec("CREATE ROLE #{owner} #{login}")
  admin.exec("CREATE DATABASE #{db}")
  conn = PG.connect(dbname: db)
  conn.exec("GRANT CONNECT ON DATABASE #{db} TO #{owner}")
  conn.exec("GRANT USAGE, CREATE ON SCHEMA public TO #{owner}")
  conn.exec("ALTER DATABASE #{db} OWNER TO #{owner}")
  conn.close
  admin
end

def ir_file(registry)
  name = registry.bluebooks.keys.first
  ir = Hecks::Projector::Exporter.call(registry).fetch(name)
  file = Tempfile.new(["rmp-", ".json"])
  file.write(JSON.generate(ir.merge(translations: [], source_text: SOURCE)))
  file.flush
  file
end

def stored_shape(db, owner)
  conn = PG.connect(dbname: db, user: owner)
  eras = Hecks::Adapters::PostgresRevision::Lineage.new(conn, "Ledger", reading: true).eras
  era = eras.first
  [eras.size, era[:hash], Hecks::Adapters::PostgresRevision::LineageManager.held_shape(era.merge(held_text: "not a bluebook"))]
ensure
  conn&.close
end

suffix = SecureRandom.hex(4)
db = "mvr_rust_proj_#{suffix}"
owner = "mvr_proj_owner_#{suffix}"
admin = scratch_database(db, owner)
begin
  registry = load_registry
  bluebook = registry.bluebooks.values.first
  file = ir_file(registry)
  _out, err, status = Open3.capture3(ARGV.fetch(0), db, owner, "Ledger", file.path)
  abort "mint_harness failed:\n#{err}" unless status.success?

  count, hash, shape = stored_shape(db, owner)
  puts JSON.generate(
    eras: count, stored_hash: hash, ruby_hash: Hecks::Runtime::StorageShape.mint_hash(bluebook),
    stored_projection: shape, ruby_projection: Hecks::Runtime::StorageShape.project(bluebook)
  )
ensure
  admin.exec("DROP DATABASE IF EXISTS #{db} WITH (FORCE)")
  admin.exec("DROP ROLE IF EXISTS #{owner}")
  admin.close
end
