#!/usr/bin/env ruby
# Mints an era with a `compute` rule and prints Postgres's compiled-SQL result as ground truth.
# Compute has no in-process Ruby reference, so the head view is the only oracle.
#
# usage: mint_and_seed_lineage_compute.rb <db_name> <owner_role> <app_role>

require "pg"
$LOAD_PATH.unshift File.expand_path("../../../../lib", __dir__)
require "hecks"
require "hecks/ports/persistence/plugins/era"
require "json"
require "tempfile"

db_name, owner_role, app_role = ARGV
unless db_name && owner_role && app_role
  abort "usage: mint_and_seed_lineage_compute.rb <db_name> <owner_role> <app_role>"
end

admin = PG.connect(dbname: "postgres")
admin.exec("DROP DATABASE IF EXISTS #{db_name} WITH (FORCE)")
admin.exec("CREATE DATABASE #{db_name}")
admin.exec("DROP ROLE IF EXISTS #{owner_role}")
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
DOMAIN = "LedgerCompute"

V1 = <<~BLUEBOOK
  Hecks.bluebook "LedgerCompute" do
    aggregate "Account" do
      identified_by :kind
      attribute :score, Score
      attribute :kind, Kind

      value_object "Score" do
        attribute :value, Integer
      end

      value_object "Kind" do
        attribute :label, String
      end
    end
  end
BLUEBOOK

V2 = <<~BLUEBOOK
  Hecks.bluebook "LedgerCompute" do
    aggregate "Account" do
      identified_by :kind
      attribute :doubled, Doubled
      attribute :kind, Kind

      value_object "Doubled" do
        attribute :value, Integer
      end

      value_object "Kind" do
        attribute :label, String
      end
    end
  end
BLUEBOOK

# Helpers as in mint_and_seed_lineage.rb.

def load_registry(source, translation_source: nil)
  registry = Hecks::Runtime::Registry.new
  loading = Hecks::Ports::Loading.bootstrap
  file = Tempfile.new(["mint-and-seed-lineage-compute-", ".bluebook"])
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
  registry
end

def label_of(source)
  Hecks::Runtime::StorageShape.mint_hash(load_registry(source).bluebooks.values.first)[0, 6]
end

def edge_source(from:, to:)
  <<~RUBY
    Hecks.data_translation("LedgerCompute", from: #{from.inspect}, to: #{to.inspect}) do
      aggregate("Account") do
        compute :score, to: :doubled, sql: "jsonb_build_object('value', (score::jsonb->>'value')::int * 2)"
      end
    end
  RUBY
end

def account_instance(aggregate, kind_label, field, int_value)
  built = Hecks::Runtime::Instance.new(aggregate: aggregate, id: kind_label)
  built[:kind] = Hecks::Runtime::Value.for(aggregate, :kind, { label: kind_label })
  built[field] = Hecks::Runtime::Value.for(aggregate, field, { value: int_value })
  built
end


registry_v1 = check!(V1, owner_url: owner_url)
aggregate_v1 = registry_v1.bluebooks.values.first.aggregate("Account")
adapter_v1 = Hecks::Adapters::PostgresEra.new(
  aggregate: aggregate_v1, settings: { database: owner_url, domain: DOMAIN, era: 1 }
)
adapter_v1.save(account_instance(aggregate_v1, "a", :score, 5))
adapter_v1.save(account_instance(aggregate_v1, "b", :score, 7))

# Record the approval mint requires, bound to the journal's current high-water ordinal.
# It must follow every era-1 write and precede the mint, or it goes stale.

from = label_of(V1)
to = label_of(V2)
translation_source = edge_source(from: from, to: to)
registry_for_edge = load_registry(V2, translation_source: translation_source)
edge = registry_for_edge.translations.find { |t| t.domain == DOMAIN && t.from == from && t.to == to }
raise "expected a real translation edge for #{DOMAIN}" unless edge

edge_digest = Hecks::Translation::Audit.edge_digest(edge)
approval_db = PG.connect(owner_url)
lineage_for_approval = Hecks::Adapters::PostgresEra::Lineage.new(approval_db, DOMAIN)
lineage_for_approval.record_approval!(from: from, to: to, edge_digest: edge_digest)
approval_db.close

# Mint refuses without the approval recorded above.

registry_v2 = check!(V2, owner_url: owner_url, translation_source: translation_source, role: app_role)
aggregate_v2 = registry_v2.bluebooks.values.first.aggregate("Account")
adapter_v2 = Hecks::Adapters::PostgresEra.new(
  # owner_url, not the app role: same backfill-permission gap as mint_and_seed_lineage.rb.
  aggregate: aggregate_v2, settings: { database: owner_url, domain: DOMAIN, era: 2 }
)
adapter_v2.save(account_instance(aggregate_v2, "c", :doubled, 20))

# Ground truth: Postgres's compiled SQL, read as the owner.

# domain-qualified (docs/decisions/0059) — Naming.snake("LedgerCompute") == "ledger_compute"
raw = PG.connect(owner_url).exec("SELECT id, state FROM ledger_compute_account_head ORDER BY id")
ground_truth_rows = raw.map { |row| [row["id"], JSON.parse(row["state"])] }

puts JSON.generate({
                     db_name: db_name, app_role: app_role, domain: DOMAIN, era: 2, storage_name: "account",
  rows: ground_truth_rows
                   })
