require "spec_helper"
require "fileutils"
require "tmpdir"
require "open3"
require "json"

# Proves the all-Rust `hecks-build` (rust/build), which reads the bluebooks with `hecks-parse`,
# generates a tree byte-identical to `hecks project_rust`, which builds the IR from the live
# registry. Both run `hecks-codegen`, so this holds the two IR producers to each other. It runs
# with --no-build, comparing generated source, not artifacts.
RSpec.describe "hecks-build (rust/build) pipeline parity", :io do
  # HB_-prefixed: spec/load_hygiene_spec.rb rejects same-named top-level constants across spec
  # files, and a describe block's constants land on Object.
  HB_ROOT = InMemoryDomain::ROOT
  HB_GENERATED_ROOT = File.join(HB_ROOT, "rust/src/generated")
  HB_CARGO_TOML = File.join(HB_ROOT, "rust/Cargo.toml")
  HECKS_BUILD_DIR = File.join(HB_ROOT, "rust/build")
  HECKS_BUILD_BINARY = File.join(HECKS_BUILD_DIR, "target", "debug", "hecks-build")

  # Built when an example of this file runs, not when the file loads: a shard that excludes
  # `:io` loads every spec file, and a cargo hiccup at load aborted the whole shard.
  def self.build_hecks_build!
    out, status = Open3.capture2e("cargo", "build", chdir: HECKS_BUILD_DIR)
    raise "cargo build failed for rust/build:\n#{out}" unless status.success?
    raise "cargo build did not produce #{HECKS_BUILD_BINARY}" unless File.executable?(HECKS_BUILD_BINARY)
  end

  # What only the live registry can supply to `hecks project_rust`: persistence bindings, the
  # optional seams `rust/host` reads, translation edges and the verbatim source text.
  # `hecks-parse` reads none of them, so `ir.json` (and `metadata.rs`, which embeds it) match only
  # without them. `lineage` is not among them: `hecks-build` derives it from the hecksagon and
  # world text, and the two must agree on which aggregates are lineage-capable (compliance binds
  # three through its world).
  HB_REGISTRY_ONLY_IR_KEYS = %w[persistence authorization membership identity newsletter newsletter_issues
                                payments registrations payment_connection translations approvals
                                source_text].freeze

  # [domain, dirs its run touches]: the target, `meta`, and any framework chapter it attaches.
  HB_PARITY_DOMAINS = {
    "examples/pizzas"                    => %w[pizzas meta],
    "examples/banking"                   => %w[banking governance identity meta],
    "examples/roster"                    => %w[roster meta],
    "examples/compliance"                => %w[compliance governance meta],
    "examples/embryonaut_vendoring_demo" => %w[embryonaut_vendoring_demo widgets meta]
  }.freeze

  before(:context) do
    self.class.build_hecks_build!
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

  def run_project_rust!(domain)
    _out, err, status = Open3.capture3({ "PATH" => ENV.fetch("PATH", nil) }, *RepoTool.argv("project_rust"), domain,
                                       chdir: HB_ROOT)
    raise "hecks project_rust #{domain} failed:\n#{err}" unless status.success?
  end

  def run_hecks_build!(domain)
    _out, err, status = Open3.capture3({ "PATH" => ENV.fetch("PATH", nil) }, HECKS_BUILD_BINARY, domain, "--no-build",
                                       chdir: HB_ROOT)
    raise "hecks-build #{domain} --no-build failed:\n#{err}" unless status.success?
  end

  # The file's text as the two commands must agree on it: `ir.json` without the registry-only keys,
  # and no `metadata.rs`, which is that same IR as a string.
  def comparable_text(dir, basename)
    path = File.join(dir, basename)
    case basename
    when "metadata.rs" then nil
    when "ir.json" then JSON.pretty_generate(JSON.parse(File.read(path)).except(*HB_REGISTRY_ONLY_IR_KEYS))
    else File.read(path)
    end
  end

  def files_in(dir)
    Dir.glob(File.join(dir, "*")).select { |path| File.file?(path) }.map { |path| File.basename(path) }.sort
  end

  # Copies the generated output of `dirs` into a fresh scratch directory and answers its path.
  def snapshot_generated(dirs)
    Dir.mktmpdir("hecks-build-pipeline-spec-ruby").tap do |snapshot|
      dirs.each { |dir| FileUtils.cp_r(File.join(HB_GENERATED_ROOT, dir), File.join(snapshot, dir)) }
    end
  end

  def file_list_problem(dir, ruby_files, rust_files)
    return if rust_files == ruby_files

    "#{dir}: hecks-build's own file list differs from hecks project_rust's — " \
      "ruby: #{ruby_files.inspect}, hecks-build: #{rust_files.inspect}"
  end

  def text_problems(dir, ruby_dir, rust_dir, basenames)
    basenames.filter_map do |basename|
      ruby_text = comparable_text(ruby_dir, basename)
      next if ruby_text.nil? || comparable_text(rust_dir, basename) == ruby_text

      "#{dir}/#{basename}: hecks-build's output does not byte-match hecks project_rust's"
    end
  end

  # What differs between the Ruby snapshot of `dir` and what hecks-build generated, as messages.
  def dir_problems(dir, snapshot)
    ruby_dir = File.join(snapshot, dir)
    rust_dir = File.join(HB_GENERATED_ROOT, dir)
    ruby_files = files_in(ruby_dir)
    [file_list_problem(dir, ruby_files, files_in(rust_dir)), *text_problems(dir, ruby_dir, rust_dir, ruby_files)].compact
  end

  CARGO_SYNC_PROBLEM = "rust/Cargo.toml: hecks-build's own [features] sync does not byte-match hecks project_rust's".freeze

  # Runs both pipelines for `domain` and answers what differs between them, as messages.
  def pipeline_differences(domain, dirs)
    run_project_rust!(domain)
    snapshot = snapshot_generated(dirs)
    ruby_cargo_toml = File.read(HB_CARGO_TOML)
    run_hecks_build!(domain)
    problems = dirs.flat_map { |dir| dir_problems(dir, snapshot) }
    # Both commands sync the `default =` feature in rust/Cargo.toml to the same target.
    problems << CARGO_SYNC_PROBLEM unless File.read(HB_CARGO_TOML) == ruby_cargo_toml
    problems
  ensure
    FileUtils.remove_entry(snapshot) if snapshot
  end

  HB_PARITY_DOMAINS.each do |domain, dirs|
    # One end-to-end claim per domain: splitting would re-run both real pipelines for each part.
    it "#{domain}: hecks-build's own generated output matches hecks project_rust's, byte for byte" do
      expect(pipeline_differences(domain, dirs)).to be_empty
    end
  end

  describe "hecks build_wasm, opted into the all-Rust pipeline" do
    # Opted in, hecks build_wasm must delegate to `hecks-build --wasm` and yield the same .wasm.
    def run_hecks_build_wasm!(domain)
      _out, err, status = Open3.capture3({ "PATH" => ENV.fetch("PATH", nil) }, HECKS_BUILD_BINARY, domain, "--wasm",
                                         chdir: HB_ROOT)
      raise "hecks-build #{domain} --wasm failed:\n#{err}" unless status.success?
    end

    def dist_wasm = File.join(HB_ROOT, "rust", "dist", "pizzas.wasm")

    def run_project_wasm_opted_in!(domain)
      env = { "PATH" => ENV.fetch("PATH", nil), "HECKS_PARSER" => "rust", "HECKS_CODEGEN" => "rust" }
      _out, err, status = Open3.capture3(env, *RepoTool.argv("project_wasm"), domain, chdir: HB_ROOT)
      raise "hecks build_wasm (opt-in) #{domain} failed:\n#{err}" unless status.success?
    end

    it "produces the identical .wasm hecks-build --wasm produces directly, not the Ruby generator's own build" do
      run_hecks_build_wasm!("examples/pizzas")
      direct_wasm = File.binread(dist_wasm)
      run_project_wasm_opted_in!("examples/pizzas")

      expect(File.binread(dist_wasm)).to eq(direct_wasm)
    end
  end
end
