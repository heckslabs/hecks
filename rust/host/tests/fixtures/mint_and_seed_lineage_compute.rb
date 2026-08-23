#!/usr/bin/env ruby
# ADR 0029 step 7 — the highest-effort remaining case: an era minted
# with a `compute` rule, the one migration kind with NO in-process Ruby
# reference implementation at all (`Ports::Persistence::Lineage#
# translate`'s own header: "compute is deliberately not applied here...
# this transform neither imitates nor checks it"). Its only
# verification anywhere in this project is the human-approved sample
# the real audit records — mint refuses outright without a matching,
# unstale approval (`lineage_manager/minter.rb`'s own gate). This
# script is the first thing in the whole codebase that drives that gate
# for real from outside `bin/translation_audit` itself.
#
# BECAUSE there is no in-process reference transform for `compute`, this
# fixture's own "ground truth" is necessarily narrower than mint_and_
# seed_lineage.rb's: it can only be Postgres's own compiled SQL
# (`head_compiler.rb`'s `compile_compute`), read directly — proving
# "Rust's read agrees with what Postgres's compiled SQL actually
# produced," not "Rust agrees with an independent Ruby computation."
# That is the honest, narrower claim ADR 0029 itself names for this
# exact case, not a weakening introduced here.
#
# `score`/`doubled` are each wrapped in their own single-member value
# object, not bare scalars — this language refuses a scalar attribute
# directly on an aggregate outright ("attributes must use value-object
# types", meta_validator/judge.rb's own comment on that refusal), found
# live writing this fixture's first draft. `compile_compute`'s own SQL
# (head_compiler.rb) only ever extracts a FLAT `->>'` key, so the
# compute's `sql:` expression re-parses the extracted VO's own JSON
# text and rebuilds a proper `{"value": ...}` object as its result,
# rather than the compute rule needing any dotted-path support the
# generator doesn't have.
#
# usage: mint_and_seed_lineage_compute.rb <db_name> <owner_role> <app_role>

require "pg"
$LOAD_PATH.unshift File.expand_path("../../../../lib", __dir__)
require "hecksagain"
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

# ── same proven helpers mint_and_seed_lineage.rb already carries ──

def load_registry(source, translation_source: nil)
  registry = Hecksagain::Runtime::Registry.new
  loading = Hecksagain::Ports::Loading.bootstrap
  file = Tempfile.new(["mint-and-seed-lineage-compute-", ".bluebook"])
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
  registry
end

def label_of(source)
  Hecksagain::Runtime::StorageShape.mint_hash(load_registry(source).bluebooks.values.first)[0, 6]
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
  built = Hecksagain::Runtime::Instance.new(aggregate: aggregate, id: kind_label)
  built[:kind] = Hecksagain::Runtime::Value.for(aggregate, :kind, { label: kind_label })
  built[field] = Hecksagain::Runtime::Value.for(aggregate, field, { value: int_value })
  built
end

# ── era 1: mint, then real writes ──

registry_v1 = check!(V1, owner_url: owner_url)
aggregate_v1 = registry_v1.bluebooks.values.first.aggregate("Account")
adapter_v1 = Hecksagain::Adapters::PostgresEra.new(
  aggregate: aggregate_v1, settings: { database: owner_url, domain: DOMAIN, era: 1 }
)
adapter_v1.save(account_instance(aggregate_v1, "a", :score, 5))
adapter_v1.save(account_instance(aggregate_v1, "b", :score, 7))

# ── the human gate, exercised for real: compute the SAME digest
# ApprovalDigest.edge_digest computes over the real, parsed edge, and
# record it bound to the journal's CURRENT high-water ordinal — exactly
# what bin/translation_audit --approve does, just driven here instead
# of through that CLI. Must happen AFTER every era-1 write above and
# BEFORE the era-2 mint below: the approval binds to "the journal as it
# stood when the samples were read," and any write between review and
# mint would invalidate it (minter.rb's own reviewed_ordinal check). ──

from = label_of(V1)
to = label_of(V2)
translation_source = edge_source(from: from, to: to)
registry_for_edge = load_registry(V2, translation_source: translation_source)
edge = registry_for_edge.translations.find { |t| t.domain == DOMAIN && t.from == from && t.to == to }
raise "expected a real translation edge for #{DOMAIN}" unless edge

edge_digest = Hecksagain::Translation::Audit.edge_digest(edge)
approval_db = PG.connect(owner_url)
lineage_for_approval = Hecksagain::Adapters::PostgresEra::Lineage.new(approval_db, DOMAIN)
lineage_for_approval.record_approval!(from: from, to: to, edge_digest: edge_digest)
approval_db.close

# ── era 2: mint (role-fenced to app_role) — refuses outright without
# the approval just recorded, per minter.rb's own gate ──

registry_v2 = check!(V2, owner_url: owner_url, translation_source: translation_source, role: app_role)
aggregate_v2 = registry_v2.bluebooks.values.first.aggregate("Account")
adapter_v2 = Hecksagain::Adapters::PostgresEra.new(
  # owner_url, not app_url -- same ensure_head_snapshot!/backfill-
  # progress permission gap mint_and_seed_lineage.rb's own comment
  # documents; unrelated to compute specifically.
  aggregate: aggregate_v2, settings: { database: owner_url, domain: DOMAIN, era: 2 }
)
adapter_v2.save(account_instance(aggregate_v2, "c", :doubled, 20))

# ── ground truth: Postgres's OWN compiled SQL, read directly -- the
# only implementation `compute` has anywhere. Owner-authenticated (RLS
# fencing itself is proven elsewhere; this script seeds and reads,
# it doesn't re-prove the fence). ──

raw = PG.connect(owner_url).exec("SELECT id, state FROM account_head ORDER BY id")
ground_truth_rows = raw.map { |row| [row["id"], JSON.parse(row["state"])] }

puts JSON.generate({
                     db_name: db_name, app_role: app_role, domain: DOMAIN, era: 2, storage_name: "account",
  rows: ground_truth_rows
                   })
