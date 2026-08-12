require "spec_helper"
require "fileutils"
require "tmpdir"
require "open3"
require "json"

# THE STAGE 8 CAPSTONE — the differential proof that `HECKS_PARSER=rust
# HECKS_CODEGEN=rust bin/project_rust <domain>`
# (rust/project_rust_pipeline.rb: `hecks-parse resolve`/`chapter` +
# `hecks-codegen full`, ZERO `Kernel.load` of any domain bluebook)
# produces the SAME generated Rust source `bin/project_rust`'s own
# DEFAULT (Ruby, `Kernel.load`-based) path does — the plan's own
# original Stage 8 goal ("compile it entirely in rust"), verified
# end-to-end for real, not asserted once by hand. Modeled directly on
# `spec/rust_conformance_spec.rb`'s own cargo-build-then-subprocess
# pattern; `io: true` for the same reason that file is — real `cargo
# build`s happen inside `bin/project_rust` itself now (both paths), and
# real filesystem writes land in the SAME shared `rust/src/generated/`
# tree every other concurrent session's own use of `bin/project_rust`
# also writes into. `before(:context)`/`after(:context)` snapshot and
# restore that tree (plus `rust/Cargo.toml`) around this file's own
# examples, so running it leaves no trace behind for a concurrent
# session to trip over — no other spec in this repo calls
# `bin/project_rust` for real, so this is the first that needs to.
#
# TWO NAMED, DELIBERATE EXCEPTIONS to "byte-identical" — both explained
# in full in `rust/project_rust_pipeline.rb`'s own header:
#
#   - `manifest.json` is not written by the opt-in path at all —
#     coverage bookkeeping only (`hecks-codegen full`'s own header in
#     `rust/codegen/src/main.rs`), no bearing on whether the generated
#     `.rs` source is correct.
#   - `ir.json`/`metadata.rs` differ ONLY in whether a top-level
#     `lineage` key is present. Computing it for real needs the
#     domain's own `.hecksagon` PERSISTENCE BINDS actually interpreted
#     (`Runtime::EraCheck.adapter_for`) — and `persisted_by`/
#     `projected_by` are the plan's own named, PERMANENT open-vocabulary
#     escape (ADR 0023): shape-matched, contents dropped, never
#     interpreted, everywhere in `rust/parser`. Squarely inside this
#     plan's own "Era-aware/translation-rule codegen" non-goal, not a
#     gap this stage's scope covers.
#
# Every OTHER generated file — every aggregate `.rs`, `registry.rs`,
# `mod.rs`, `merged.rs`, for the target chapter, every attached
# framework chapter, AND `meta` — must be genuinely byte-identical.
RSpec.describe "bin/project_rust opt-in Rust pipeline parity", io: true do
  ROOT = InMemoryDomain::ROOT
  GENERATED_ROOT = File.join(ROOT, "rust/src/generated")
  CARGO_TOML = File.join(ROOT, "rust/Cargo.toml")
  PROJECT_RUST = File.join(ROOT, "bin/project_rust")

  # [domain, dirs THIS domain's own run touches] — the target itself,
  # `meta` (every run regenerates it — both paths' own header explains
  # why), plus any framework chapter it attaches (`banking` alone pulls
  # in `governance`/`identity` via `uses_framework`; `pizzas` attaches
  # none).
  PARITY_DOMAINS = {
    "examples/pizzas" => %w[pizzas meta],
    "examples/banking" => %w[banking governance identity meta],
  }.freeze

  IGNORED_BASENAMES = %w[manifest.json].freeze
  LINEAGE_ONLY_BASENAMES = %w[ir.json metadata.rs].freeze

  before(:context) do
    @generated_backup = Dir.mktmpdir("project-rust-pipeline-spec-backup")
    FileUtils.cp_r(GENERATED_ROOT, File.join(@generated_backup, "generated"))
    FileUtils.cp(CARGO_TOML, File.join(@generated_backup, "Cargo.toml"))
  end

  after(:context) do
    FileUtils.rm_rf(GENERATED_ROOT)
    FileUtils.cp_r(File.join(@generated_backup, "generated"), GENERATED_ROOT)
    FileUtils.cp(File.join(@generated_backup, "Cargo.toml"), CARGO_TOML)
    FileUtils.remove_entry(@generated_backup)
  end

  def run_project_rust!(domain, extra_env)
    env = { "PATH" => ENV["PATH"] }.merge(extra_env)
    _out, err, status = Open3.capture3(env, PROJECT_RUST, domain, chdir: ROOT)
    raise "bin/project_rust #{extra_env.inspect} #{domain} failed:\n#{err}" unless status.success?
  end

  def files_in(dir)
    Dir.glob(File.join(dir, "*")).select { |path| File.file?(path) }.map { |path| File.basename(path) }.sort
  end

  # `ir.json`'s own text, or `metadata.rs`'s EMBEDDED `IR_JSON` constant
  # decoded back out — `String#inspect` (what `rust/project_rust_
  # pipeline.rb::write_sidecars!` and `domain_generator.rb` both use to
  # build that constant) produces valid Ruby string-literal source by
  # definition, so `eval`-ing the captured literal is the exact inverse
  # of the encoding step, on LOCALLY-GENERATED, trusted text (never
  # anything resembling untrusted input) — not a general-purpose parser
  # this spec would otherwise have to hand-write.
  def embedded_ir_json(basename, text)
    return text if basename == "ir.json"

    match = text.match(/pub const IR_JSON: &str = (".*");\n\z/m)
    raise "no 'pub const IR_JSON: &str = ...;' found in metadata.rs" unless match

    eval(match[1]) # rubocop:disable Security/Eval
  end

  # Both sides, stripped of the one key this stage's own opt-in path
  # deliberately doesn't compute yet (this file's own header explains
  # why) — compared as PARSED JSON, not raw bytes, so this assertion
  # doesn't also depend on `JSON.pretty_generate` formatting being
  # reproduced exactly by the `eval` round-trip above (it already is,
  # but the structural comparison is the actually load-bearing claim).
  def without_lineage(json_text)
    JSON.parse(json_text).tap { |hash| hash.delete("lineage") }
  end

  PARITY_DOMAINS.each do |domain, dirs|
    it "#{domain}: the opt-in Rust path's generated output matches the default Ruby path's, file for file (modulo the named manifest.json/lineage gaps)" do
      run_project_rust!(domain, {})

      ruby_snapshot = Dir.mktmpdir("project-rust-pipeline-spec-ruby")
      dirs.each { |dir| FileUtils.cp_r(File.join(GENERATED_ROOT, dir), File.join(ruby_snapshot, dir)) }

      run_project_rust!(domain, { "HECKS_PARSER" => "rust", "HECKS_CODEGEN" => "rust" })

      dirs.each do |dir|
        ruby_dir = File.join(ruby_snapshot, dir)
        rust_dir = File.join(GENERATED_ROOT, dir)

        ruby_files = files_in(ruby_dir)
        rust_files = files_in(rust_dir)
        expect(rust_files).to eq(ruby_files - IGNORED_BASENAMES),
          "#{dir}: the opt-in path's own file list differs from the default path's (beyond the named manifest.json gap) — " \
          "ruby: #{ruby_files.inspect}, rust: #{rust_files.inspect}"

        (ruby_files - IGNORED_BASENAMES).each do |basename|
          ruby_text = File.read(File.join(ruby_dir, basename))
          rust_text = File.read(File.join(rust_dir, basename))

          if LINEAGE_ONLY_BASENAMES.include?(basename)
            expect(without_lineage(embedded_ir_json(basename, rust_text))).to eq(without_lineage(embedded_ir_json(basename, ruby_text))),
              "#{dir}/#{basename}: differs beyond the documented `lineage` gap"
          else
            expect(rust_text).to eq(ruby_text), "#{dir}/#{basename}: the opt-in Rust path's output does not byte-match the default Ruby path's"
          end
        end
      end
    ensure
      FileUtils.remove_entry(ruby_snapshot) if ruby_snapshot
    end
  end
end
