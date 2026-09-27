#!/usr/bin/env ruby
# Mints a real era 2 in a scratch database, fencing a non-superuser app role to it.
# Used by rust/host's journal.rs RLS-refusal test; mirrors postgres_era/lineage_spec.rb.
#
# usage: mint_stale_era.rb <db_name> <owner_role> <app_role>

require "pg"
$LOAD_PATH.unshift File.expand_path("../../../../lib", __dir__)
require "hecks"
require "hecks/ports/persistence/plugins/era"
require "tempfile"

db_name, owner_role, app_role = ARGV
unless db_name && owner_role && app_role
  abort "usage: mint_stale_era.rb <db_name> <owner_role> <app_role>"
end

admin = PG.connect(dbname: "postgres")
admin.exec("DROP DATABASE IF EXISTS #{db_name} WITH (FORCE)")
admin.exec("CREATE DATABASE #{db_name}")
admin.exec("DROP ROLE IF EXISTS #{owner_role}")
# No SUPERUSER or BYPASSRLS: either makes FORCE ROW LEVEL SECURITY a no-op.
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

# Renaming one attribute is enough to change the storage shape and trigger a mint.
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

# Helpers from lineage_spec.rb, taking owner_url as an argument.

def load_registry(source, translation_source: nil)
  registry = Hecks::Runtime::Registry.new
  loading = Hecks::Ports::Loading.bootstrap
  file = Tempfile.new(["mint-stale-era-", ".bluebook"])
  file.write(source)
  file.flush
  Hecks.with_registry(registry) do
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
  Hecks::Adapters::PostgresEra::LineageManager.check!(
    registry: registry, bluebook: bluebook, current_text: source, settings: settings
  )
end

def label_of(source)
  Hecks::Runtime::StorageShape.mint_hash(load_registry(source).bluebooks.values.first)[0, 6]
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
