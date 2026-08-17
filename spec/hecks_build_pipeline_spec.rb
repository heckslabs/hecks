require "spec_helper"
require "fileutils"
require "tmpdir"
require "open3"
require "json"

# THE FOLLOW-UP TO `spec/project_rust_pipeline_spec.rb`, continuing from
# where Stage 8 (`/Users/christopheryoung/.claude/plans/sequential-petting-whale.md`)
# left off: that spec proves the OPT-IN Ruby-orchestrated all-Rust
# pipeline (`HECKS_PARSER=rust HECKS_CODEGEN=rust bin/project_rust
# <domain>`, still itself a Ruby process shelling out to `hecks-parse`/
# `hecks-codegen`) matches the DEFAULT Ruby path. THIS spec proves the
# NEW all-the-way-down Rust binary — `rust/build/` (`hecks-build`),
# which does the SAME job with NO Ruby process involved anywhere in its
# own execution, not even for orchestration — produces the IDENTICAL
# generated tree the opt-in Ruby pipeline does, for real, byte-exact,
# not asserted once by hand.
#
# `hecks-build` is called here with `--no-build` (generate source only,
# skip the `cargo build --release` step for the domain's own compiled
# artifact) — matching `spec/project_rust_pipeline_spec.rb`'s own
# pattern of comparing GENERATED SOURCE, not compiled output, and
# keeping this spec fast enough for the normal `bundle exec rspec` loop.
# The real, actual `cargo build --release` (and, separately,
# `cargo build --release --target wasm32-wasip1`) path IS exercised —
# just not from inside this spec: see this stage's own report for the
# real commands run and their real output, plus `cargo test --release`
# inside `rust/` (the `from_json_round_trip.rs` integration tests)
# passing against `hecks-build`'s own generated banking tree.
#
# NO `lineage`-only EXCEPTION NEEDED HERE: both `hecks-build`
# (`lineage_pass.rs`) and the opt-in Ruby pipeline it's compared against
# here (`rust/project_rust_pipeline.rb::derive_lineage`) compute the
# `lineage` key for real now, from the same narrow `.hecksagon`
# `persisted_by`-bind text scan, ported line for line — so
# `ir.json`/`metadata.rs` are expected to be PLAIN BYTE-IDENTICAL too,
# same as every other generated file. `manifest.json` stays the one
# remaining named, deliberate gap (coverage bookkeeping only) — neither
# side writes it, so the file-list comparison below never sees it on
# either side and needs no exclusion list.
RSpec.describe "hecks-build (rust/build) pipeline parity", io: true do
  # PREFIXED (HB_*), not the bare names `spec/project_rust_pipeline_spec.rb`
  # already uses (ROOT/GENERATED_ROOT/CARGO_TOML/PROJECT_RUST/
  # PARITY_DOMAINS) — `spec/load_hygiene_spec.rb`'s own "lets no two spec
  # files disagree about a top-level constant" check flags ANY same-name
  # top-level constant across spec files (a `describe` block's constant
  # assignment lands at Object, not a lexical scope of its own), even
  # when both definitions happen to hold the same value — so this file
  # needs its own names, not a re-litigation of that check.
  HB_ROOT = InMemoryDomain::ROOT
  HB_GENERATED_ROOT = File.join(HB_ROOT, "rust/src/generated")
  HB_CARGO_TOML = File.join(HB_ROOT, "rust/Cargo.toml")
  HB_PROJECT_RUST = File.join(HB_ROOT, "bin/project_rust")
  HECKS_BUILD_DIR = File.join(HB_ROOT, "rust/build")
  HECKS_BUILD_BINARY = File.join(HECKS_BUILD_DIR, "target", "debug", "hecks-build")

  def self.build_hecks_build!
    built = system("cargo", "build", chdir: HECKS_BUILD_DIR, out: File::NULL, err: File::NULL)
    raise "cargo build failed for rust/build — run `cargo build` there directly to see why" unless built
    raise "cargo build did not produce #{HECKS_BUILD_BINARY}" unless File.executable?(HECKS_BUILD_BINARY)
  end

  build_hecks_build!

  # [domain, dirs THIS domain's own run touches] — same table
  # `spec/project_rust_pipeline_spec.rb` already uses, for the same
  # reason (the target itself, `meta` — every run regenerates it — plus
  # any framework chapter it attaches).
  HB_PARITY_DOMAINS = {
    "examples/pizzas"  => %w[pizzas meta],
    "examples/banking" => %w[banking governance identity meta],
  }.freeze

  before(:context) do
    @generated_backup = Dir.mktmpdir("hecks-build-pipeline-spec-backup")
    FileUtils.cp_r(HB_GENERATED_ROOT, File.join(@generated_backup, "generated"))
    FileUtils.cp(HB_CARGO_TOML, File.join(@generated_backup, "Cargo.toml"))
  end

  after(:context) do
    FileUtils.rm_rf(HB_GENERATED_ROOT)
    FileUtils.cp_r(File.join(@generated_backup, "generated"), HB_GENERATED_ROOT)
    FileUtils.cp(File.join(@generated_backup, "Cargo.toml"), HB_CARGO_TOML)
    FileUtils.remove_entry(@generated_backup)
  end

  def run_project_rust_opt_in!(domain)
    env = { "PATH" => ENV["PATH"], "HECKS_PARSER" => "rust", "HECKS_CODEGEN" => "rust" }
    _out, err, status = Open3.capture3(env, HB_PROJECT_RUST, domain, chdir: HB_ROOT)
    raise "bin/project_rust (opt-in) #{domain} failed:\n#{err}" unless status.success?
  end

  def run_hecks_build!(domain)
    _out, err, status = Open3.capture3({ "PATH" => ENV["PATH"] }, HECKS_BUILD_BINARY, domain, "--no-build", chdir: HB_ROOT)
    raise "hecks-build #{domain} --no-build failed:\n#{err}" unless status.success?
  end

  def files_in(dir)
    Dir.glob(File.join(dir, "*")).select { |path| File.file?(path) }.map { |path| File.basename(path) }.sort
  end

  HB_PARITY_DOMAINS.each do |domain, dirs|
    it "#{domain}: hecks-build's own generated output matches the opt-in Ruby-orchestrated Rust pipeline's, byte for byte" do
      run_project_rust_opt_in!(domain)

      ruby_snapshot = Dir.mktmpdir("hecks-build-pipeline-spec-ruby")
      dirs.each { |dir| FileUtils.cp_r(File.join(HB_GENERATED_ROOT, dir), File.join(ruby_snapshot, dir)) }
      ruby_cargo_toml = File.read(HB_CARGO_TOML)

      run_hecks_build!(domain)

      dirs.each do |dir|
        ruby_dir = File.join(ruby_snapshot, dir)
        rust_dir = File.join(HB_GENERATED_ROOT, dir)

        ruby_files = files_in(ruby_dir)
        rust_files = files_in(rust_dir)
        expect(rust_files).to eq(ruby_files),
                              "#{dir}: hecks-build's own file list differs from the opt-in Ruby pipeline's — " \
                              "ruby: #{ruby_files.inspect}, hecks-build: #{rust_files.inspect}"

        ruby_files.each do |basename|
          ruby_text = File.read(File.join(ruby_dir, basename))
          rust_text = File.read(File.join(rust_dir, basename))
          expect(rust_text).to eq(ruby_text),
                               "#{dir}/#{basename}: hecks-build's output does not byte-match the opt-in Ruby pipeline's"
        end
      end

      # `rust/Cargo.toml`'s own `[features]` sync — the `default =`
      # feature both pipelines set to THIS run's own target should agree
      # too (both ran, back to back, targeting the same domain).
      hecks_build_cargo_toml = File.read(HB_CARGO_TOML)
      expect(hecks_build_cargo_toml).to eq(ruby_cargo_toml),
                                        "rust/Cargo.toml: hecks-build's own [features] sync does not byte-match the opt-in Ruby pipeline's"
    ensure
      FileUtils.remove_entry(ruby_snapshot) if ruby_snapshot
    end
  end
end
