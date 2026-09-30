require "spec_helper"
require "fileutils"
require "tmpdir"
require "open3"
require "json"

# Proves the all-Rust `hecks-build` (rust/build) generates a tree byte-identical to the opt-in
# Ruby-orchestrated pipeline. It runs with --no-build, comparing generated source, not artifacts.
RSpec.describe "hecks-build (rust/build) pipeline parity", :io do
  # HB_-prefixed: spec/load_hygiene_spec.rb rejects same-named top-level constants across spec
  # files, and a describe block's constants land on Object.
  HB_ROOT = InMemoryDomain::ROOT
  HB_GENERATED_ROOT = File.join(HB_ROOT, "rust/src/generated")
  HB_CARGO_TOML = File.join(HB_ROOT, "rust/Cargo.toml")
  HECKS_BUILD_DIR = File.join(HB_ROOT, "rust/build")
  HECKS_BUILD_BINARY = File.join(HECKS_BUILD_DIR, "target", "debug", "hecks-build")

  def self.build_hecks_build!
    built = system("cargo", "build", chdir: HECKS_BUILD_DIR, out: File::NULL, err: File::NULL)
    raise "cargo build failed for rust/build — run `cargo build` there directly to see why" unless built
    raise "cargo build did not produce #{HECKS_BUILD_BINARY}" unless File.executable?(HECKS_BUILD_BINARY)
  end

  build_hecks_build!

  # [domain, dirs its run touches]: the target, `meta`, and any framework chapter it attaches.
  HB_PARITY_DOMAINS = {
    "examples/pizzas"                    => %w[pizzas meta],
    "examples/banking"                   => %w[banking governance identity meta],
    "examples/roster"                    => %w[roster meta],
    "examples/compliance"                => %w[compliance governance meta],
    "examples/embryonaut_vendoring_demo" => %w[embryonaut_vendoring_demo widgets meta]
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
    env = { "PATH" => ENV.fetch("PATH", nil), "HECKS_PARSER" => "rust", "HECKS_CODEGEN" => "rust" }
    _out, err, status = Open3.capture3(env, *RepoTool.argv("project_rust"), domain, chdir: HB_ROOT)
    raise "hecks project_rust (opt-in) #{domain} failed:\n#{err}" unless status.success?
  end

  def run_hecks_build!(domain)
    _out, err, status = Open3.capture3({ "PATH" => ENV.fetch("PATH", nil) }, HECKS_BUILD_BINARY, domain, "--no-build",
                                       chdir: HB_ROOT)
    raise "hecks-build #{domain} --no-build failed:\n#{err}" unless status.success?
  end

  def files_in(dir)
    Dir.glob(File.join(dir, "*")).select { |path| File.file?(path) }.map { |path| File.basename(path) }.sort
  end

  HB_PARITY_DOMAINS.each do |domain, dirs|
    # One end-to-end claim per domain: splitting would re-run both real pipelines for each part.
    # rubocop:disable-next RSpec/ExampleLength
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

      # Both pipelines sync the `default =` feature in rust/Cargo.toml to the same target.
      hecks_build_cargo_toml = File.read(HB_CARGO_TOML)
      expect(hecks_build_cargo_toml).to eq(ruby_cargo_toml),
                                        "rust/Cargo.toml: hecks-build's own [features] sync does not byte-match " \
                                        "the opt-in Ruby pipeline's"
    ensure
      FileUtils.remove_entry(ruby_snapshot) if ruby_snapshot
    end
  end

  describe "hecks build_wasm, opted into the all-Rust pipeline" do
    # Opted in, hecks build_wasm must delegate to `hecks-build --wasm` and yield the same .wasm.
    def run_hecks_build_wasm!(domain)
      _out, err, status = Open3.capture3({ "PATH" => ENV.fetch("PATH", nil) }, HECKS_BUILD_BINARY, domain, "--wasm",
                                         chdir: HB_ROOT)
      raise "hecks-build #{domain} --wasm failed:\n#{err}" unless status.success?
    end

    it "produces the identical .wasm hecks-build --wasm produces directly, not the Ruby generator's own build" do
      domain = "examples/pizzas"
      dist_wasm = File.join(HB_ROOT, "rust", "dist", "pizzas.wasm")

      run_hecks_build_wasm!(domain)
      direct_wasm = File.binread(dist_wasm)

      env = { "PATH" => ENV.fetch("PATH", nil), "HECKS_PARSER" => "rust", "HECKS_CODEGEN" => "rust" }
      _out, err, status = Open3.capture3(env, *RepoTool.argv("project_wasm"), domain, chdir: HB_ROOT)
      raise "hecks build_wasm (opt-in) #{domain} failed:\n#{err}" unless status.success?

      expect(File.binread(dist_wasm)).to eq(direct_wasm)
    end
  end
end
