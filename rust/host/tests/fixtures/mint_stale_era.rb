#!/usr/bin/env ruby
# Used ONLY by rust/host's own RLS-refusal test (journal.rs's
# `a_stale_era_write_is_refused_by_postgres_rls_not_this_crate`) — mints
# a REAL era 2 via Ruby's own LineageManager against a scratch Postgres
# database, leaving era 1 superseded and a non-superuser app role fenced
# to era 2. That's the exact real-world condition
# `append_lineage_mutation`'s own claim needs to hold against: staleness
# is refused by Postgres's OWN RLS row policy, not by anything this
# crate checks itself. Mirrors
# spec/adapters/driven/postgres_era/lineage_spec.rb's own
# "fences a deployment's app role" setup (LINEAGE_OWNER/LINEAGE_ROLE
# pattern, load_registry/check!/hash_of helpers) almost verbatim rather
# than reinventing it — only the db/role names are parameterized.
#
# usage: mint_stale_era.rb <db_name> <owner_role> <app_role>

require "pg"
$LOAD_PATH.unshift File.expand_path("../../../../lib", __dir__)
require "hecksagain"
require "tempfile"

db_name, owner_role, app_role = ARGV
unless db_name && owner_role && app_role
  abort "usage: mint_stale_era.rb <db_name> <owner_role> <app_role>"
end

admin = PG.connect(dbname: "postgres")
admin.exec("DROP DATABASE IF EXISTS #{db_name} WITH (FORCE)")
admin.exec("CREATE DATABASE #{db_name}")
admin.exec("DROP ROLE IF EXISTS #{owner_role}")
# Plain CREATE ROLE ... LOGIN — no SUPERUSER, no BYPASSRLS, matching
# lineage_spec.rb's own reasoning: either attribute makes FORCE ROW
# LEVEL SECURITY a no-op, the same way it already is for a superuser
# dev connection, and the whole point of this fixture is to prove the
# fence against a role it can actually constrain.
admin.exec("CREATE ROLE #{owner_role} LOGIN")
admin.exec("DROP ROLE IF EXISTS #{app_role}")
admin.exec("CREATE ROLE #{app_role} LOGIN")
admin.close

grant = PG.connect(dbname: db_name)
grant.exec("GRANT CONNECT ON DATABASE #{db_name} TO #{owner_role}")
grant.exec("GRANT CONNECT ON DATABASE #{db_name} TO #{app_role}")
grant.exec("GRANT USAGE, CREATE ON SCHEMA public TO #{owner_role}")
grant.exec("GRANT USAGE ON SCHEMA public TO #{app_role}")
grant.close

owner_url = "postgres://#{owner_role}@localhost/#{db_name}"

# Minimal shape drift: renaming one attribute is enough to change
# StorageShape.project's output and trigger a real mint — nothing about
# this test needs a richer domain than that.
v1 = <<~BLUEBOOK
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

v2 = <<~BLUEBOOK
  Hecks.bluebook "Ledger" do
    aggregate "Account" do
      identified_by :kind
      attribute :amount, Money
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

# ── the proven helpers from lineage_spec.rb, unchanged apart from
# taking owner_url as an argument instead of a shared constant ──

def load_registry(source, translation_source: nil)
  registry = Hecksagain::Runtime::Registry.new
  loading = Hecksagain::Ports::Loading.bootstrap
  file = Tempfile.new(["mint-stale-era-", ".bluebook"])
  file.write(source)
  file.flush
  Hecksagain.with_registry(registry) do
    loading.load_library
    Kernel.eval(source, TOPLEVEL_BINDING, file.path, 1)
    eval(translation_source) if translation_source
  end
  registry
ensure
  file&.close!
end

def check!(source, owner_url:, translation_source: nil, role: nil)
  registry = load_registry(source, translation_source: translation_source)
  bluebook = registry.bluebooks.values.first
  settings = { database: owner_url }
  settings[:role] = role if role
  Hecksagain::Adapters::PostgresEra::LineageManager.check!(
    registry: registry, bluebook: bluebook, current_text: source, settings: settings
  )
end

def label_of(source)
  Hecksagain::Runtime::StorageShape.mint_hash(load_registry(source).bluebooks.values.first)[0, 6]
end

def edge_source(from:, to:)
  <<~RUBY
    Hecks.data_translation("Ledger", from: #{from.inspect}, to: #{to.inspect}) do
      aggregate("Account") do
        rename :cost, to: :amount
      end
    end
  RUBY
end

check!(v1, owner_url: owner_url)
from = label_of(v1)
to = label_of(v2)
check!(v2, owner_url: owner_url, translation_source: edge_source(from: from, to: to), role: app_role)

puts "ok"
