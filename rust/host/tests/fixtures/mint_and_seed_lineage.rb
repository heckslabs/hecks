#!/usr/bin/env ruby
# ADR 0029 step 4/5 — the Ruby side of the differential-parity harness.
# Extends mint_stale_era.rb's own DB/role-provisioning + mint pattern
# (that file's own header names it as reused almost verbatim from
# lineage_spec.rb) with what that fixture deliberately doesn't do:
# writing REAL data through Ruby's own PostgresEra adapter under era 1,
# minting era 2, writing more real data under era 2, then emitting
# Ruby's own INDEPENDENTLY COMPUTED ground truth for the merged head as
# JSON on stdout — what spec/rust_host_lineage_conformance_spec.rb
# diffs lineage_harness's own answer against.
#
# "Independently computed" is deliberate, not just "read the same
# Postgres view twice": era 1's rows are translated through
# Ports::Persistence::Lineage#translate — Ruby's OWN in-process
# reference implementation of the portable rule kinds (rename/move/
# convert/drop/backfill), the exact mechanism the real Layer 2 audit
# (translation/audit/layer_two.rb) diffs Postgres's compiled SQL
# against. A ground truth built by re-reading Postgres's own <storage>_
# head view would only prove "two SQL clients agree," which is a
# structurally weaker claim than "Rust's read agrees with Ruby's own
# reference transform" — see this file's own compute/rekey sibling
# for the one case where that weaker claim is genuinely the best
# available (no in-process reference exists for compute/rekey at all).
#
# NOT spec/corpus/fixtures/lineage_v1*.json — read directly, those
# three files (a) target lineage/tail_merge.rb's fork-reconciliation
# scenario specifically (their own note text: "the fork's own... must
# refuse it by name"), a different and more advanced case than era-
# boundary read/write parity; (b) mix "Lineage::Acct" (the command
# namespace) with "Lineage::Account" (the query verb) — no bluebook
# anywhere in this repo declares either, and nothing in the tree
# consumes them, so this reads as a staged, never-finished draft
# carrying its own naming bug, not something safe to load as-is. Left
# for a follow-on that wants tail_merge coverage specifically; this
# fixture authors its own minimal, working two-era history instead,
# matching mint_stale_era.rb's OWN proven "Ledger"/"Account" shape
# rather than inventing a third.
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
# app_role gets no connection URL of its own here — the RSpec caller
# (spec/rust_host_lineage_conformance_spec.rb) connects as app_role
# through lineage_harness, the ONLY thing in this harness meant to
# exercise that role's own grants (see the adapter_v2 comment below).

DOMAIN = "Ledger"

# SAME shape mint_stale_era.rb proved — one attribute rename (cost ->
# amount) is enough to change StorageShape.project's output and trigger
# a real mint; nothing about this harness needs a richer domain.
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

# ── the proven helpers mint_stale_era.rb already carries, `check!`
# additionally returning its own registry so this script can read real
# instances/translations back through it ──

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

# ── era 1: mint, then real writes through Ruby's own adapter ──

registry_v1 = check!(V1, owner_url: owner_url)
aggregate_v1 = registry_v1.bluebooks.values.first.aggregate("Account")
adapter_v1 = Hecks::Adapters::PostgresEra.new(
  aggregate: aggregate_v1, settings: { database: owner_url, domain: DOMAIN, era: 1 }
)
era1_writes = { "biz" => 100, "pers" => 250 }
era1_writes.each { |kind, cents| adapter_v1.save(account_instance(aggregate_v1, kind, cents: cents)) }

# ── era 2: mint (role-fenced to app_role), then real writes ──

from = label_of(V1)
to = label_of(V2)
registry_v2 = check!(V2, owner_url: owner_url, translation_source: edge_source(from: from, to: to), role: app_role)
aggregate_v2 = registry_v2.bluebooks.values.first.aggregate("Account")
adapter_v2 = Hecks::Adapters::PostgresEra.new(
  # owner_url, NOT app_url — a fresh PostgresEra.new re-runs
  # ensure_head_snapshot!'s idempotent backfill check
  # (head_compiler.rb), which touches hecks_backfill_progress;
  # grant_role! never grants that bookkeeping table to the app role
  # (only the journal/head_snapshot/head_view an app role's own real
  # traffic touches), because in real deployment a fresh aggregate's
  # snapshot is already backfilled by the SAME owner-authenticated
  # mint boot before any app-role connection is ever made. RLS
  # fencing itself is proven separately and already, by journal.rs's
  # own a_stale_era_write_is_refused_by_postgres_rls_not_this_crate
  # test — this script's job is seeding real data, not re-proving that.
  aggregate: aggregate_v2, settings: { database: owner_url, domain: DOMAIN, era: 2 }
)
era2_writes = { "gift" => 5 }
era2_writes.each { |kind, cents| adapter_v2.save(account_instance(aggregate_v2, kind, cents: cents)) }

# ── ground truth: era 1's raw writes translated through Ruby's OWN
# Ports::Persistence::Lineage#translate (the same in-process reference
# the real Layer 2 audit diffs Postgres's compiled SQL against), merged
# with era 2's own untranslated writes — independent of anything this
# script has already read back FROM Postgres. ──

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
  # JSON round-trip: same normalization spec/rust_conformance_spec.rb's
  # own comparisons already rely on, so a symbol-vs-string key
  # difference can never register as a real disagreement.
  [id, JSON.parse(JSON.generate(state))]
end

puts JSON.generate({
                     db_name: db_name, app_role: app_role, domain: DOMAIN, era: 2, storage_name: "account",
  rows: ground_truth_rows
                   })
