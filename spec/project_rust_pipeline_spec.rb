require "spec_helper"
require "fileutils"
require "tmpdir"
require "open3"
require "json"

# ADR 0054a, B3 — the differential proof that `bin/project_rust <domain>`'s
# new default (Ruby builds the IR, `hecks-build --ir-dir` generates:
# `hecks-codegen full` + sidecars + root mod.rs + Cargo.toml) writes the
# SAME tree the Ruby generator it replaced does
# (`HECKS_RUBY_CODEGEN=1 bin/project_rust <domain>`, the temporary escape
# hatch kept until B5 deletes `rust/project/`).
#
# No exemptions: both paths start from the same Ruby-built IR, so every
# file — every aggregate `.rs`, `registry.rs`, `mod.rs`, `merged.rs`,
# `manifest.json`, `ir.json`, `metadata.rs`, for the target chapter, every
# attached framework chapter, AND `meta` — plus `rust/Cargo.toml` and the
# root `mod.rs` must be byte-identical. (The `HECKS_PARSER=rust
# HECKS_CODEGEN=rust` opt-in this spec used to compare is a deprecated
# no-op now; `spec/hecks_build_pipeline_spec.rb` covers the Ruby-free
# parse path.) The codegen drift check (ci-checks.yml) holds the default
# path to the committed tree across its whole corpus; this spec keeps the
# two generators held to each other while both exist.
#
# `io: true` — real `cargo build`s and real writes into the shared
# `rust/src/generated/` tree, snapshotted and restored around this file.
#
# `ruby_codegen_parity: true` — NOT A CI GATE SINCE ADR 0054a's B4. The
# drift check still holds the default path to the committed tree; this
# comparison against the escape hatch runs on demand only (see
# spec_helper.rb's note) and is deleted with `rust/project/` in B5.
RSpec.describe "bin/project_rust default (hecks-build) vs the Ruby generator", :io, :ruby_codegen_parity do
  # `InMemoryDomain::ROOT` directly, not aliased to a local `ROOT` — a
  # bare `ROOT` collided with word_coverage_spec.rb's own (see
  # load_hygiene_spec.rb's own top-level-constant check).
  GENERATED_ROOT = File.join(InMemoryDomain::ROOT, "rust/src/generated")
  CARGO_TOML = File.join(InMemoryDomain::ROOT, "rust/Cargo.toml")
  PROJECT_RUST = File.join(InMemoryDomain::ROOT, "bin/project_rust")

  # [domain, dirs THIS domain's own run touches] — the target itself,
  # `meta` (every run regenerates it), plus any framework chapter it
  # attaches (`banking` pulls in `governance`/`identity` via
  # `uses_framework`; `pizzas` attaches none).
  PARITY_DOMAINS = {
    "examples/pizzas"  => %w[pizzas meta],
    "examples/banking" => %w[banking governance identity meta],
    "examples/roster"  => %w[roster meta]
  }.freeze

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
    env = { "PATH" => ENV.fetch("PATH", nil) }.merge(extra_env)
    _out, err, status = Open3.capture3(env, PROJECT_RUST, domain, chdir: InMemoryDomain::ROOT)
    raise "bin/project_rust #{extra_env.inspect} #{domain} failed:\n#{err}" unless status.success?
  end

  def files_in(dir)
    Dir.glob(File.join(dir, "*")).select { |path| File.file?(path) }.map { |path| File.basename(path) }.sort
  end

  PARITY_DOMAINS.each do |domain, dirs|
    it "#{domain}: the hecks-build default writes the Ruby generator's tree, file for file and byte for byte" do
      run_project_rust!(domain, { "HECKS_RUBY_CODEGEN" => "1" })

      ruby_snapshot = Dir.mktmpdir("project-rust-pipeline-spec-ruby")
      dirs.each { |dir| FileUtils.cp_r(File.join(GENERATED_ROOT, dir), File.join(ruby_snapshot, dir)) }
      ruby_root_mod = File.read(File.join(GENERATED_ROOT, "mod.rs"))
      ruby_cargo_toml = File.read(CARGO_TOML)

      run_project_rust!(domain, {})

      dirs.each do |dir|
        ruby_dir = File.join(ruby_snapshot, dir)
        rust_dir = File.join(GENERATED_ROOT, dir)

        expect(files_in(rust_dir)).to eq(files_in(ruby_dir)), "#{dir}: the file lists differ"

        files_in(ruby_dir).each do |basename|
          ours = File.read(File.join(rust_dir, basename))
          expect(ours).to eq(File.read(File.join(ruby_dir, basename))),
                          "#{dir}/#{basename}: hecks-build's output does not byte-match the Ruby generator's"
        end
      end
      expect(File.read(File.join(GENERATED_ROOT, "mod.rs"))).to eq(ruby_root_mod)
      expect(File.read(CARGO_TOML)).to eq(ruby_cargo_toml)
    ensure
      FileUtils.remove_entry(ruby_snapshot) if ruby_snapshot
    end
  end
end
