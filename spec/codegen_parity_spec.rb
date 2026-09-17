require "spec_helper"
require "json"
require "fileutils"
require "tmpdir"
require "open3"
require_relative "../rust/project"

# THE DIFFERENTIAL HARNESS FOR STAGE 7 (codegen) — modeled directly on
# spec/parser_parity_spec.rb's own proven pattern (cargo-build-then-
# subprocess, byte-exact comparison, a real corpus enumeration, an
# honestly-shrinking CODEGEN_PENDING_MEMBERS table with a REASON per entry) and on
# spec/rust_conformance_spec.rb's own cargo-build-inside-rspec convention.
#
# TWO SLICES, TWO CHECKS. The first Stage 7 slice ported the value-object/
# entity/record/JSON-codec/closed-set/invariant/identity-extraction half
# of `rust/project/*.rb` (types.rb, fielded.rb, json_codec.rb,
# constraints.rb, naming.rb, exemplar.rb, plus a Rust port of Evaluator/
# Resolver's PARSE step for expr_emitter.rb) — real and independently
# verifiable, but not a WHOLE generated `.rs` file, because
# `domain_generator.rb#call` interleaves that slice with commands/ports
# into one file per aggregate. That gap is what this continuation closes:
# `rust/codegen/src/{commands,mutations,bridging,queries,read_models,
# reactions,ports,registry,domain_generator,literal}.rs` port the
# command-dispatch half (argument gating, role checking, given/ensures
# wiring, mutation application, JSON routing), and `hecks-codegen domain`
# (a new CLI subcommand alongside `prelude`, backed by
# `rust/codegen/src/domain_generator.rs`, a from-scratch port of
# `DomainGenerator.call` — NOT built by reusing `prelude.rs`, which
# omits entity commands entirely; see that file's own header) generates
# the FULL per-chapter output: every aggregate `.rs` file, `registry.rs`,
# `mod.rs`.
#
# EVERY member gets the whole-file check. The older prelude-only check
# (and its `WHOLE_FILE_MEMBERS` split) is gone: once every hand-listed
# member reached whole-file byte-exactness it had nothing left to run.
# Members that don't match yet sit in `CODEGEN_PENDING_MEMBERS`, where
# the same whole-file check runs as RSpec `pending`.
#
# NOT covered even by the whole-file check: `metadata.rs` (embeds
# `ir.json` as a Rust string constant via Ruby's own `JSON.pretty_generate
# (ir).inspect` — this crate has no JSON pretty-printer, only a reader,
# see `json.rs`'s own header), `ir.json` itself (the same reason), and
# `manifest.json` (bookkeeping about what got generated, not the
# generated source itself) — all three are real, named, deliberately
# out-of-scope gaps in `rust/codegen/src/domain_generator.rs`'s own
# header, not silently dropped. `mod.rs` IS covered (cheap, deterministic,
# no JSON pretty-printer needed) but compared against Ruby's OWN
# `DomainGenerator.call` output directly (this spec's own whole-file `it`
# block, below) — NOT against the checked-in `rust/src/generated/
# <member>/mod.rs`, which `bin/project_rust` itself (not
# `DomainGenerator.call`) appends a `pub mod merged;` line to as a
# separate, later post-processing step (`bin/project_rust`'s own
# multi-chapter merge, out of this generator's own scope per the plan) —
# comparing against the checked-in file would be comparing against the
# wrong artifact.
#
# `mark_append_optional_fields!` (mutations.rb) is STILL NOT PORTED —
# `Json` (this crate's own IR value type) has no mutation API (see
# `json.rs`'s own header), and every real corpus field that pass would
# touch already declares `optional: true` directly in its own bluebook
# source, so the mutating pass is a no-op everywhere this corpus actually
# reaches it (confirmed true for `banking`/`bluebook_language`, the two
# members that exercise an `append` fed by a caller-omittable argument).
# Left named here as a real, confirmed-currently-harmless gap, not
# silently dropped — see `mutations.rs`'s own header for the full
# argument.
# `io: true` — a `cargo build` subprocess spawn is real I/O by this
# suite's own convention (see spec_helper.rb's `io: true` note), and
# `build_codegen!` used to run at `describe`-body load time, unconditionally,
# on every `bundle exec rspec` — RSpec still evaluates a group's top-level
# body while building the example tree even when every example in it gets
# excluded by the `io: true` filter, so tagging the group alone wasn't
# enough; the build itself had to move into a `before(:context)` hook,
# which — unlike plain body code — really is skipped when excluded.
RSpec.describe "Rust codegen parity (hecks-codegen)", :io do
  CODEGEN_DIR = File.expand_path("../rust/codegen", __dir__)
  CODEGEN_BINARY = File.join(CODEGEN_DIR, "target", "debug", "hecks-codegen")

  def self.build_codegen!
    built = system("cargo", "build", chdir: CODEGEN_DIR, out: File::NULL, err: File::NULL)
    raise "cargo build failed for rust/codegen — run `cargo build` there directly to see why" unless built
    raise "cargo build did not produce #{CODEGEN_BINARY}" unless File.executable?(CODEGEN_BINARY)
  end

  before(:context) { self.class.build_codegen! }

  def self.json_shaped(payload) = JSON.parse(JSON.generate(payload), symbolize_names: true)

  # THE SAME sequence `bin/project_rust` itself loads a single-bluebook
  # domain through (persistence/extraction ports, memory + prism +
  # postgres adapters, then the domain's own `.bluebook`) — reused
  # directly so this can't silently drift from what "the real generator's
  # own input" means.
  def self.domain_ir(bluebook_path, domain_name)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(InMemoryDomain::POSTGRES_ERA_ADAPTER)
      InMemoryDomain.load_bluebook_files(bluebook_path)
    end
    json_shaped(Hecks::Projector::Exporter.call(registry).fetch(domain_name))
  end

  # THE ONE MEMBER THAT CAN'T GO THROUGH `domain_ir` — same reason
  # spec/parser_parity_spec.rb's own `ruby_ir_json` special-cases it:
  # `MetaValidator.grammar_registry` is the only door that sets
  # `@bootstrapping = true` around the self-hosted grammar's own nine-file
  # load (aggregate.bluebook references ValueObject/Entity, both declared
  # in LATER files — the ordinary `Hecks.bluebook`-triggered path refuses
  # immediately).
  def self.meta_ir
    json_shaped(Hecks::Projector::Exporter.call(Hecks::Bluebook::MetaValidator.grammar_registry).fetch("Bluebook"))
  end

  # [member name, ir-loader lambda] — DERIVED, not hand-listed:
  #   - every in-repo Rust domain `bin/project_rust` has generated
  #     (`Hecks::Corpus.rust_regen_order`, the list the drift check
  #     regenerates), loaded from its bluebook directory the way
  #     bin/project_rust loads it, under the chapter its header declares
  #   - every framework chapter generated as a side effect of a
  #     `uses_framework` domain (`Corpus.rust_framework_chapters`)
  #   - the self-hosted language, `bluebook_language` (the `meta` module)
  # spec/corpus_rust_spec.rb proves every generated module is one of these
  # or `embryonaut` (external, below).
  def self.corpus_member(name, source)
    [name, -> { domain_ir(source, Hecks::Corpus.chapter_name_of(Hecks::Corpus.bluebook_files(source) || source)) }]
  end

  CODEGEN_CORPUS_MEMBERS = [
    *Hecks::Corpus.rust_regen_order.map { |domain| corpus_member(domain.feature, Hecks::Corpus.bluebook_dir(domain.dir)) },
    *Hecks::Corpus.rust_framework_chapters.map do |stem|
      corpus_member(stem, File.join(Hecks::Corpus::ROOT, "lib/hecks/framework/bluebook/#{stem}.bluebook"))
    end,
    # SAME SHAPE, `uses_embryonaut_bluebook`'s own side (docs/decisions/
    # 0058) — a vendored package generated as a side effect of some other
    # domain's own regen, same "no merged.rs, no Cargo feature of its
    # own" fact `rust_framework_chapters` already carries, just sourced
    # from `:vendored` corpus members (nested inside a consuming
    # example's own `vendor/embryonaut_bluebooks/`) instead of this gem's
    # own `lib/hecks/framework/bluebook/`.
    *Hecks::Corpus.rust_vendored_chapters.map do |stem|
      member = Hecks::Corpus.members(:vendored).find { |m| m.stem == stem }
      corpus_member(stem, Hecks::Corpus.bluebook_dir(member.path))
    end,
    ["bluebook_language", -> { meta_ir }]
  ].freeze

  # SHRINK-ONLY: a derived member whose Rust codegen still disagrees with
  # Ruby's, with the bug that owns it. It runs the same whole-file check
  # as RSpec `pending`, so the day it matches, the example FAILS until the
  # entry is deleted here.
  CODEGEN_PENDING_MEMBERS = {
    "corrections" => "BUG#32's Rust half: `Ledger.Void` (`sets :entries, remove: :sequence`) — rust/codegen never " \
                     "ported the `remove` mutation op, and `hecks-codegen domain` panics with " \
                     "\"unsupported mutation op \\\"remove\\\"\""
  }.freeze

  it "finds at least one real corpus member" do
    expect(CODEGEN_CORPUS_MEMBERS).not_to be_empty
  end

  it "pends only members it actually derives" do
    expect(CODEGEN_PENDING_MEMBERS.keys - CODEGEN_CORPUS_MEMBERS.map(&:first)).to be_empty
  end

  # EMBRYONAUT IS EXTERNAL, not pending: its bluebook lives in its own
  # repository, which owes its codegen parity. This fails the day an
  # in-repo source for it appears, so it joins the derived members.
  it "embryonaut: has no in-repo source, so its own repository owns its codegen parity" do
    expect(Hecks::Corpus::RUST_ELSEWHERE.fetch("embryonaut").check).to eq(:external)
    expect(CODEGEN_CORPUS_MEMBERS.map(&:first)).not_to include("embryonaut")
  end

  CODEGEN_CORPUS_MEMBERS.each do |name, ir_loader|
    it "#{name}: Rust hecks-codegen's FULL domain .rs output (every aggregate file + registry.rs + " \
       "mod.rs) is byte-identical to Ruby's" do
      pending CODEGEN_PENDING_MEMBERS.fetch(name) if CODEGEN_PENDING_MEMBERS.key?(name)
      ir = ir_loader.call

      Dir.mktmpdir do |tmp|
        ruby_dir = File.join(tmp, "ruby")
        rust_dir = File.join(tmp, "rust")

        # Ruby's own `DomainGenerator.call` — the SAME real function
        # `bin/project_rust` calls, not a reimplementation. Also writes
        # metadata.rs/ir.json/manifest.json into `ruby_dir` (this method's
        # own contract) — deliberately not compared (see this file's own
        # header on why those three are out of scope for this crate).
        RustProjection::DomainGenerator.call(ir, name, ruby_dir, name)

        ir_json_path = File.join(tmp, "ir.json")
        File.write(ir_json_path, JSON.pretty_generate(ir))
        stdout, status = Open3.capture2(CODEGEN_BINARY, "domain", ir_json_path, name, name, rust_dir)
        expect(status.success?).to be(true), "hecks-codegen domain failed for #{name}:\n#{stdout}"

        # Compare exactly the files THIS crate claims to generate
        # (aggregate `.rs` files, `registry.rs`, `mod.rs`) — never
        # metadata.rs/ir.json/manifest.json, which aren't ported (see
        # this file's own header).
        compared_names = generated_aggregate_basenames(ir) + ["registry.rs", "mod.rs"]

        compared_names.each do |basename|
          ruby_path = File.join(ruby_dir, basename)
          rust_path = File.join(rust_dir, basename)
          expect(File.exist?(ruby_path)).to be(true),
                                            "#{name}/#{basename}: Ruby's own DomainGenerator.call didn't write this file — " \
                                            "compared_names is stale"
          expect(File.exist?(rust_path)).to be(true), "#{name}/#{basename}: hecks-codegen domain didn't write this file"

          ruby_text = File.read(ruby_path)
          rust_text = File.read(rust_path)
          expect(rust_text).to eq(ruby_text), "#{name}/#{basename}: Rust codegen's FULL domain output does not byte-match Ruby's"
        end
      end
    end
  end

  # Every aggregate NAME the real `DomainGenerator.call` would generate a
  # file for — mirrors that method's own `unsupported_attribute_types`
  # skip check exactly (rather than hand-listing basenames), so this can
  # never silently drift from which aggregates a real run actually emits.
  def generated_aggregate_basenames(payload)
    payload[:aggregates].filter_map do |aggregate|
      vo_by_name = aggregate[:value_objects].to_h { |vo| [vo[:name], vo] }
      next nil if RustProjection::Projector.unsupported_attribute_types(aggregate, vo_by_name).any?

      "#{aggregate[:name].downcase}.rs"
    end
  end
end
