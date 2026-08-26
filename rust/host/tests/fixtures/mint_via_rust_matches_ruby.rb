#!/usr/bin/env ruby
# ADR-0030-in-progress step 8 — the differential proof `mint_harness`
# (rust/host/src/bin/mint_harness.rs) exists for: THE SAME declared
# edge, minted INDEPENDENTLY by Ruby's own `LineageManager.check!`/
# `mint!` and by Rust's own boot-gate mint path (`mint_harness`, not a
# synthetic shortcut — the real `decide_boot_action` -> hold_first/
# audit_before_mint/mint_era sequence `bootstrap`'s own boot gate
# runs), must produce byte-identical `_head` views.
#
# Every EARLIER example in spec/rust_host_lineage_conformance_spec.rb
# (ADR 0029) proves Rust READS/WRITES an era RUBY minted correctly —
# structurally weaker than this: it never proves Rust's OWN mint (the
# DDL, the compiled matview, the translated data) agrees with Ruby's
# independently-produced one. This is the first fixture in this
# codebase where BOTH sides of the diff are a REAL mint, in two
# different languages, against two separate scratch databases.
#
# Each side writes through its OWN real generic write path — Ruby's
# `PostgresEra#save`, Rust's `lineage_harness`'s own `write` op (already
# separately proven correct by this spec file's OWN second example) —
# not a raw byte-identical INSERT, so this proves the FULL stack agrees
# (mint AND write), the actual end-to-end claim ADR-0030-in-progress
# makes, not a narrower "the DDL text matches" one.
#
# `ir.json` for each shape comes from `Hecks::Projector::Exporter.
# call`/`.translations` DIRECTLY — the SAME calls `bin/project_rust`
# itself makes to build the real `ir.json` sidecar every deployed
# domain ships — not a hand-approximated JSON shape this fixture
# invented for itself.
#
# usage: mint_via_rust_matches_ruby.rb <mint_harness_binary> <lineage_harness_binary>

require "pg"
$LOAD_PATH.unshift File.expand_path("../../../../lib", __dir__)
require "hecks"
require "json"
require "tempfile"
require "open3"
require "securerandom"

mint_harness_binary, lineage_harness_binary = ARGV
unless mint_harness_binary && lineage_harness_binary
  abort "usage: mint_via_rust_matches_ruby.rb <mint_harness_binary> <lineage_harness_binary>"
end

suffix = SecureRandom.hex(4)
DOMAIN = "Ledger"
RUBY_DB = "mvr_ruby_#{suffix}"
RUST_DB = "mvr_rust_#{suffix}"
OWNER = "mvr_owner_#{suffix}"

admin = PG.connect(dbname: "postgres")
[RUBY_DB, RUST_DB].each { |db| admin.exec("DROP DATABASE IF EXISTS #{db} WITH (FORCE)") }
admin.exec("DROP ROLE IF EXISTS #{OWNER}")
admin.exec("CREATE ROLE #{OWNER} LOGIN")
[RUBY_DB, RUST_DB].each do |db|
  admin.exec("CREATE DATABASE #{db}")
  conn = PG.connect(dbname: db)
  conn.exec("GRANT CONNECT ON DATABASE #{db} TO #{OWNER}")
  conn.exec("GRANT USAGE, CREATE ON SCHEMA public TO #{OWNER}")
  conn.exec("ALTER DATABASE #{db} OWNER TO #{OWNER}")
  conn.close
end
admin.close

ruby_owner_url = "postgres://#{OWNER}@localhost/#{RUBY_DB}"

# SAME shape mint_and_seed_lineage.rb (ADR 0029) already proved — one
# attribute rename is enough to change StorageShape.project's own
# output and trigger a real mint.
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

def load_registry(source, translation_source: nil)
  registry = Hecks::Runtime::Registry.new
  loading = Hecks::Ports::Loading.bootstrap
  file = Tempfile.new(["mint-via-rust-", ".bluebook"])
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

from_label = label_of(V1)
to_label = label_of(V2)
edge_src = edge_source(from: from_label, to: to_label)

# Real Exporter output, same calls bin/project_rust itself makes —
# see this file's own header on why this beats a hand-built ir.json.
def export_ir(source, translation_source:)
  registry = load_registry(source, translation_source: translation_source)
  domain_name = registry.bluebooks.keys.first
  ir = Hecks::Projector::Exporter.call(registry).fetch(domain_name)
  ir.merge(
    translations: Hecks::Projector::Exporter.translations(registry).select { |edge| edge[:domain] == domain_name },
    source_text: source
  )
end

# Kept as `Tempfile` objects, not just their `.path` strings: a Tempfile
# with no live reference is eligible for GC at any point, and its
# finalizer unlinks the underlying file — exactly the flake this fixture
# hit in CI ("reading /tmp/mvr-v1-*.json: No such file or directory"),
# nondeterministically on either file depending on GC timing, because
# `.tap { |f| ... }.path` discards the only reference to `f` on this
# same line. `v1_ir_file`/`v2_ir_file` stay reachable as top-level
# locals for the rest of this script, so the file can't be unlinked out
# from under `run!(mint_harness_binary, ..., v1_ir_path)` below.
v1_ir_file = Tempfile.new(["mvr-v1-", ".json"])
v1_ir_file.write(JSON.generate(export_ir(V1, translation_source: nil)))
v1_ir_file.flush
v1_ir_path = v1_ir_file.path

v2_ir_file = Tempfile.new(["mvr-v2-", ".json"])
v2_ir_file.write(JSON.generate(export_ir(V2, translation_source: edge_src)))
v2_ir_file.flush
v2_ir_path = v2_ir_file.path

def run!(*cmd, stdin_data: nil)
  stdout, status = Open3.capture2(*cmd, stdin_data: stdin_data)
  raise "#{cmd.join(' ')} failed (exit #{status.exitstatus}):\n#{stdout}" unless status.success?

  stdout
end

def check_ruby!(source, owner_url:, translation_source: nil, role: nil)
  registry = load_registry(source, translation_source: translation_source)
  bluebook = registry.bluebooks.values.first
  settings = { database: owner_url }
  settings[:role] = role if role
  Hecks::Adapters::PostgresEra::LineageManager.check!(
    registry: registry, bluebook: bluebook, current_text: source, settings: settings
  )
  registry
end

def account_instance(aggregate, kind_label, cents:)
  field = aggregate.attribute(:amount) ? :amount : :cost
  built = Hecks::Runtime::Instance.new(aggregate: aggregate, id: kind_label)
  built[:kind] = Hecks::Runtime::Value.for(aggregate, :kind, { label: kind_label })
  built[field] = Hecks::Runtime::Value.for(aggregate, field, { cents: cents })
  built
end

def read_head(db_name, owner)
  rows = PG.connect(dbname: db_name, user: owner).exec("SELECT id, state FROM account_head ORDER BY id")
  rows.map { |row| [row["id"], JSON.parse(row["state"])] }
end

# ── era 1: each side mints, then writes real data through its OWN
# generic write path ──

registry_v1 = check_ruby!(V1, owner_url: ruby_owner_url)
aggregate_v1 = registry_v1.bluebooks.values.first.aggregate("Account")
adapter_v1 = Hecks::Adapters::PostgresEra.new(aggregate: aggregate_v1, settings: { database: ruby_owner_url, domain: DOMAIN, era: 1 })
era1_writes = { "biz" => 100, "pers" => 250 }
era1_writes.each { |kind, cents| adapter_v1.save(account_instance(aggregate_v1, kind, cents: cents)) }

run!(mint_harness_binary, RUST_DB, OWNER, DOMAIN, v1_ir_path)
era1_writes.each do |kind, cents|
  op = { "op" => "write", "aggregate" => "#{DOMAIN}::Account", "id" => kind, "state" => { "cost" => { "cents" => cents }, "kind" => { "label" => kind } } }
  result = JSON.parse(run!(lineage_harness_binary, RUST_DB, OWNER, DOMAIN, "1", stdin_data: JSON.generate({ "operations" => [op] })))
  raise "rust era-1 write of #{kind.inspect} failed: #{result}" unless result.dig("results", 0, "ok")
end

# ── era 2: each side mints (the real audit/approval-gate path, on the
# Rust side, runs for real here — this is the FIRST place in this
# codebase Rust's own audit_before_mint is proven against a domain it
# didn't author its own fixture data for by hand), then writes ──

registry_v2 = check_ruby!(V2, owner_url: ruby_owner_url, translation_source: edge_src, role: nil)
aggregate_v2 = registry_v2.bluebooks.values.first.aggregate("Account")
adapter_v2 = Hecks::Adapters::PostgresEra.new(aggregate: aggregate_v2, settings: { database: ruby_owner_url, domain: DOMAIN, era: 2 })
era2_writes = { "gift" => 5 }
era2_writes.each { |kind, cents| adapter_v2.save(account_instance(aggregate_v2, kind, cents: cents)) }

run!(mint_harness_binary, RUST_DB, OWNER, DOMAIN, v2_ir_path)
era2_writes.each do |kind, cents|
  op = { "op" => "write", "aggregate" => "#{DOMAIN}::Account", "id" => kind, "state" => { "amount" => { "cents" => cents }, "kind" => { "label" => kind } } }
  result = JSON.parse(run!(lineage_harness_binary, RUST_DB, OWNER, DOMAIN, "2", stdin_data: JSON.generate({ "operations" => [op] })))
  raise "rust era-2 write of #{kind.inspect} failed: #{result}" unless result.dig("results", 0, "ok")
end

# ── read BOTH sides' final account_head directly — same connection
# shape (owner, no RLS fencing involved), the most direct possible
# comparison of what each language's own mint actually produced ──

puts JSON.generate({
                      ruby_db: RUBY_DB, rust_db: RUST_DB, owner: OWNER,
                      ruby_rows: read_head(RUBY_DB, OWNER), rust_rows: read_head(RUST_DB, OWNER)
                    })
