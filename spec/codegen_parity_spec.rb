require "spec_helper"
require "json"
require "fileutils"
require "tmpdir"
require "open3"
require_relative "../rust/project"
require_relative "support/ruby_codegen_prelude"

# THE DIFFERENTIAL HARNESS FOR STAGE 7 (codegen) — modeled directly on
# spec/parser_parity_spec.rb's own proven pattern (cargo-build-then-
# subprocess, byte-exact comparison, a real corpus enumeration, an
# honestly-shrinking PENDING_MEMBERS table with a REASON per entry) and on
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
# `WHOLE_FILE_MEMBERS` names which `CODEGEN_CORPUS_MEMBERS` get the
# STRONGER, whole-file check below instead of the older prelude-only one
# — every member not listed there stays on prelude-only, unchanged and
# un-weakened (regression-safe, per the stage's own instructions). As of
# this continuation, ALL SIX real corpus members reach full whole-file
# byte-exactness on the first genuine attempt — including `banking`
# (entity commands on SafeDepositBox/ATMCard, arithmetic mutations,
# process managers, cross-domain policies) and `bluebook_language` (the
# self-hosted grammar's own nine-file chapter) — leaving the prelude-only
# loop with nothing left to run except `embryonaut`'s own always-pending
# entry (a structural gap: no local `.bluebook` source to load, unrelated
# to anything ported here).
#
# NOT covered even for a `WHOLE_FILE_MEMBERS` entry: `metadata.rs` (embeds
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
RSpec.describe "Rust codegen parity (hecks-codegen)" do
  CODEGEN_DIR = File.expand_path("../rust/codegen", __dir__)
  CODEGEN_BINARY = File.join(CODEGEN_DIR, "target", "debug", "hecks-codegen")

  def self.build_codegen!
    built = system("cargo", "build", chdir: CODEGEN_DIR, out: File::NULL, err: File::NULL)
    raise "cargo build failed for rust/codegen — run `cargo build` there directly to see why" unless built
    raise "cargo build did not produce #{CODEGEN_BINARY}" unless File.executable?(CODEGEN_BINARY)
  end

  build_codegen!

  def self.json_shaped(ir) = JSON.parse(JSON.generate(ir), symbolize_names: true)

  # THE SAME sequence `bin/project_rust` itself loads a single-bluebook
  # domain through (persistence/extraction ports, memory + prism +
  # postgres adapters, then the domain's own `.bluebook`) — reused
  # directly so this can't silently drift from what "the real generator's
  # own input" means.
  def self.domain_ir(bluebook_path, domain_name)
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(InMemoryDomain::POSTGRES_ADAPTER)
      Kernel.load(bluebook_path)
    end
    json_shaped(Hecksagain::Projector::Exporter.call(registry).fetch(domain_name))
  end

  # THE ONE MEMBER THAT CAN'T GO THROUGH `domain_ir` — same reason
  # spec/parser_parity_spec.rb's own `ruby_ir_json` special-cases it:
  # `MetaValidator.grammar_registry` is the only door that sets
  # `@bootstrapping = true` around the self-hosted grammar's own nine-file
  # load (aggregate.bluebook references ValueObject/Entity, both declared
  # in LATER files — the ordinary `Hecks.bluebook`-triggered path refuses
  # immediately).
  def self.meta_ir
    json_shaped(Hecksagain::Projector::Exporter.call(Hecksagain::Bluebook::MetaValidator.grammar_registry).fetch("Bluebook"))
  end

  # [member name, ir-loader lambda] — a REAL corpus member each,
  # enumerated by hand for now (not yet `Dir.glob`-derived the way
  # spec/parser_parity_spec.rb's own PARITY_CORPUS_MEMBERS is — Stage 7's
  # own scope is narrower than "every corpus member parses", see
  # PENDING_MEMBERS below for what's genuinely still open and why).
  CODEGEN_CORPUS_MEMBERS = [
    ["pizzas", -> { domain_ir(File.join(InMemoryDomain::ROOT, "examples/pizzas/bluebook/pizzas.bluebook"), "Pizzas") }],
    ["identity", -> { domain_ir(File.join(InMemoryDomain::ROOT, "lib/hecksagain/framework/bluebook/identity.bluebook"), "Identity") }],
    ["governance", -> { domain_ir(File.join(InMemoryDomain::ROOT, "lib/hecksagain/framework/bluebook/governance.bluebook"), "Governance") }],
    ["compliance", -> { domain_ir(File.join(InMemoryDomain::ROOT, "examples/compliance/bluebook/compliance.bluebook"), "Compliance") }],
    ["banking", -> { domain_ir(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook"), "Banking") }],
    ["bluebook_language", -> { meta_ir }],
  ].freeze

  # A REAL, per-member reason — never a placeholder. See this file's own
  # header on why Stage 7 doesn't reach "empty" here (the plan explicitly
  # doesn't require it to, unlike Stage 6's parsing-side table).
  PENDING_MEMBERS = {
    "embryonaut" => "Its own bluebook source lives in a separate, sibling repository (embryonaut_console) not " \
                     "checked out here — only rust/src/generated/embryonaut's own already-compiled output exists " \
                     "in THIS repo, with no `.bluebook` this spec's own Kernel.load-based domain_ir helper can " \
                     "load. A real follow-up item once that repo's source is reachable from a codegen-parity run, " \
                     "not a shape/algorithm gap in rust/codegen itself.",
  }.freeze

  # Corpus members that reach FULL whole-file byte-exactness — every
  # generated `.rs` file `DomainGenerator.call` writes for the chapter
  # (aggregate files + registry.rs + mod.rs), not just the prelude prefix.
  # These get the STRONGER check below instead of the prelude-only one;
  # every other `CODEGEN_CORPUS_MEMBERS` entry stays on prelude-only.
  #
  # ALL SIX real corpus members reach it — including `banking` (entity
  # commands on SafeDepositBox/ATMCard, arithmetic mutations, process
  # managers, cross-domain policies) and `bluebook_language` (the
  # self-hosted grammar's own nine-file chapter) — leaving only
  # `embryonaut` on `PENDING_MEMBERS` (a structural gap: no local
  # `.bluebook` source to load, unrelated to anything ported this stage).
  WHOLE_FILE_MEMBERS = %w[pizzas identity governance compliance banking bluebook_language].freeze

  it "finds at least one real corpus member" do
    expect(CODEGEN_CORPUS_MEMBERS).not_to be_empty
  end

  CODEGEN_CORPUS_MEMBERS.select { |name, _| WHOLE_FILE_MEMBERS.include?(name) }.each do |name, ir_loader|
    it "#{name}: Rust hecks-codegen's FULL domain .rs output (every aggregate file + registry.rs + mod.rs) is byte-identical to Ruby's" do
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
          expect(File.exist?(ruby_path)).to be(true), "#{name}/#{basename}: Ruby's own DomainGenerator.call didn't write this file — compared_names is stale"
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
  def generated_aggregate_basenames(ir)
    ir[:aggregates].filter_map do |aggregate|
      vo_by_name = aggregate[:value_objects].to_h { |vo| [vo[:name], vo] }
      next nil if RustProjection::Projector.unsupported_attribute_types(aggregate, vo_by_name).any?

      "#{aggregate[:name].downcase}.rs"
    end
  end

  CODEGEN_CORPUS_MEMBERS.reject { |name, _| WHOLE_FILE_MEMBERS.include?(name) }.each do |name, ir_loader|
    it "#{name}: Rust hecks-codegen's prelude .rs output is byte-identical to Ruby's, per aggregate" do
      ir = ir_loader.call

      Dir.mktmpdir do |tmp|
        ruby_dir = File.join(tmp, "ruby")
        rust_dir = File.join(tmp, "rust")

        RubyCodegenPrelude.write_all(ir, name, ruby_dir)

        ir_json_path = File.join(tmp, "ir.json")
        File.write(ir_json_path, JSON.pretty_generate(ir))
        stdout, status = Open3.capture2(CODEGEN_BINARY, "prelude", ir_json_path, name, rust_dir)
        expect(status.success?).to be(true), "hecks-codegen prelude failed for #{name}:\n#{stdout}"

        ruby_files = Dir.glob(File.join(ruby_dir, "*.rs")).map { |p| File.basename(p) }.sort
        rust_files = Dir.glob(File.join(rust_dir, "*.rs")).map { |p| File.basename(p) }.sort
        expect(rust_files).to eq(ruby_files),
                               "#{name}: the SET of generated aggregate files differs (unsupported-attribute " \
                               "skip decisions disagree) — ruby: #{ruby_files.inspect}, rust: #{rust_files.inspect}"

        ruby_files.each do |basename|
          ruby_text = File.read(File.join(ruby_dir, basename))
          rust_text = File.read(File.join(rust_dir, basename))
          expect(rust_text).to eq(ruby_text),
                                "#{name}/#{basename}: Rust codegen's prelude output does not byte-match Ruby's"
        end
      end
    end
  end

  PENDING_MEMBERS.each do |name, reason|
    it "#{name}: still pending — #{reason[0, 60]}..." do
      expect(reason).to be_a(String).and(satisfy("be non-empty") { |r| !r.strip.empty? })
    end
  end
end
