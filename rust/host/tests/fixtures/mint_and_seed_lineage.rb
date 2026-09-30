#!/usr/bin/env ruby
# Seeds real data across two eras through PostgresEra, then prints the merged head as JSON.
# Ground truth translates era 1 with Ports::Persistence::Lineage#translate, not the head view.
#
# usage: mint_and_seed_lineage.rb <db_name> <owner_role> <app_role>

require "pg"
$LOAD_PATH.unshift File.expand_path("../../../../lib", __dir__)
require "hecks"
require "hecks/ports/persistence/plugins/era"
require "json"
require "tempfile"

db_name, owner_role, app_role = ARGV
unless db_name && owner_role && app_role
  abort "usage: mint_and_seed_lineage.rb <db_name> <owner_role> <app_role>"
end

# A role the test connects as later needs the admin password when the server asks for one.
LOGIN_CLAUSE = ENV["PGPASSWORD"] ? "LOGIN PASSWORD '#{ENV["PGPASSWORD"].gsub("'", "''")}'" : "LOGIN"
admin = PG.connect(dbname: "postgres")
admin.exec("DROP DATABASE IF EXISTS #{db_name} WITH (FORCE)")
admin.exec("CREATE DATABASE #{db_name}")
admin.exec("DROP ROLE IF EXISTS #{owner_role}")
admin.exec("CREATE ROLE #{owner_role} #{LOGIN_CLAUSE}")
admin.exec("DROP ROLE IF EXISTS #{app_role}")
admin.exec("CREATE ROLE #{app_role} #{LOGIN_CLAUSE}")
admin.close

grant = PG.connect(dbname: db_name)
grant.exec("GRANT CONNECT ON DATABASE #{db_name} TO #{owner_role}")
grant.exec("GRANT CONNECT ON DATABASE #{db_name} TO #{app_role}")
grant.exec("GRANT USAGE, CREATE ON SCHEMA public TO #{owner_role}")
grant.exec("GRANT USAGE ON SCHEMA public TO #{app_role}")
grant.close

owner_url = "postgres://#{owner_role}@localhost/#{db_name}"
# app_role gets no URL here; the RSpec caller connects as it through lineage_harness.

DOMAIN = "Ledger"

# One attribute rename is enough to change the storage shape and trigger a mint.
V1 = <<~BLUEBOOK
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

V2 = <<~BLUEBOOK
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

# Helpers as in mint_stale_era.rb, except `check!` also returns its registry.

def load_registry(source, translation_source: nil)
  registry = Hecks::Runtime::Registry.new
  loading = Hecks::Ports::Loading.bootstrap
  file = Tempfile.new(["mint-and-seed-lineage-", ".bluebook"])
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
    Hecks.data_translation("Ledger", from: #{from.inspect}, to: #{to.inspect}) do
      aggregate("Account") do
        rename :cost, to: :amount
      end
    end
  RUBY
end

def account_instance(aggregate, kind_label, cents:)
  cost_field = aggregate.attribute(:amount) ? :amount : :cost
  built = Hecks::Runtime::Instance.new(aggregate: aggregate, id: kind_label)
  built[:kind] = Hecks::Runtime::Value.for(aggregate, :kind, { label: kind_label })
  built[cost_field] = Hecks::Runtime::Value.for(aggregate, cost_field, { cents: cents })
  built
end


registry_v1 = check!(V1, owner_url: owner_url)
aggregate_v1 = registry_v1.bluebooks.values.first.aggregate("Account")
adapter_v1 = Hecks::Adapters::PostgresEra.new(
  aggregate: aggregate_v1, settings: { database: owner_url, domain: DOMAIN, era: 1 }
)
era1_writes = { "biz" => 100, "pers" => 250 }
era1_writes.each { |kind, cents| adapter_v1.save(account_instance(aggregate_v1, kind, cents: cents)) }


from = label_of(V1)
to = label_of(V2)
registry_v2 = check!(V2, owner_url: owner_url, translation_source: edge_source(from: from, to: to), role: app_role)
aggregate_v2 = registry_v2.bluebooks.values.first.aggregate("Account")
adapter_v2 = Hecks::Adapters::PostgresEra.new(
  # owner_url, not the app role: a fresh PostgresEra re-runs the backfill check, which touches
  # hecks_backfill_progress, a table grant_role! never gives the app role.
  aggregate: aggregate_v2, settings: { database: owner_url, domain: DOMAIN, era: 2 }
)
era2_writes = { "gift" => 5 }
era2_writes.each { |kind, cents| adapter_v2.save(account_instance(aggregate_v2, kind, cents: cents)) }

# Ground truth: era 1 translated in-process, merged with era 2's untranslated writes.

lineage = Hecks::Ports::Persistence::Lineage.for(registry_v2, DOMAIN, aggregate_v2)
raise "expected a real translation edge for Account" unless lineage

translated_era1 = era1_writes.map do |kind, cents|
  entry = Hecks::Ports::Persistence::Entry.new(
    operation: "save", id: kind, state: { cost: { cents: cents }, kind: { label: kind } }, mirrors: nil
  )
  translated = lineage.translate(entry)
  [translated.id, translated.state]
end

untranslated_era2 = era2_writes.map do |kind, cents|
  [kind, { amount: { cents: cents }, kind: { label: kind } }]
end

ground_truth_rows = (translated_era1 + untranslated_era2).map do |id, state|
  # JSON round-trip so symbol-vs-string key differences never register as disagreement.
  [id, JSON.parse(JSON.generate(state))]
end

puts JSON.generate({
                     db_name: db_name, app_role: app_role, domain: DOMAIN, era: 2, storage_name: "account",
  rows: ground_truth_rows
                   })
