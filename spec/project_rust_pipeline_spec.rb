require "spec_helper"
require "fileutils"
require "tmpdir"
require "open3"
require "json"

# Differential proof that `HECKS_PARSER=rust HECKS_CODEGEN=rust hecks project_rust <domain>` emits
# the same Rust as the default Ruby path: every file byte-identical except the exemptions below.
RSpec.describe "hecks project_rust opt-in Rust pipeline parity", :io do
  # Not aliased to a local `ROOT`: a bare `ROOT` collides with word_coverage_spec.rb's.
  GENERATED_ROOT = File.join(InMemoryDomain::ROOT, "rust/src/generated")
  CARGO_TOML = File.join(InMemoryDomain::ROOT, "rust/Cargo.toml")

  # [domain, dirs its run touches]: the target, `meta`, and any attached framework chapters.
  # `roster` has a policy with a real `where` (OnSeatAssignedHonorFront), pinning `where_ast`.
  PARITY_DOMAINS = {
    "examples/pizzas"                    => %w[pizzas meta],
    "examples/banking"                   => %w[banking governance identity meta],
    "examples/roster"                    => %w[roster meta],
    "examples/compliance"                => %w[compliance governance meta],
    # Vendored package (`attaches ... from: :vendor`, ADR 0058): counterpart of banking's
    # `attaches` proof.
    "examples/embryonaut_vendoring_demo" => %w[embryonaut_vendoring_demo widgets meta]
  }.freeze

  IGNORED_BASENAMES = %w[manifest.json].freeze

  # Both paths write these, but the opt-in pipeline has no translation pass, so the `translations`
  # key differs: presence is checked, the byte comparison is skipped.
  CONTENT_EXEMPT_BASENAMES = %w[ir.json metadata.rs].freeze

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
    _out, err, status = Open3.capture3(env, *RepoTool.argv("project_rust"), domain, chdir: InMemoryDomain::ROOT)
    raise "hecks project_rust #{extra_env.inspect} #{domain} failed:\n#{err}" unless status.success?
  end

  def files_in(dir)
    Dir.glob(File.join(dir, "*")).select { |path| File.file?(path) }.map { |path| File.basename(path) }.sort
  end

  PARITY_DOMAINS.each do |domain, dirs|
    it "#{domain}: the opt-in Rust path's generated output matches the default Ruby path's, file for file " \
       "(modulo the named manifest.json/ir.json/metadata.rs gaps)" do
      run_project_rust!(domain, {})

      ruby_snapshot = Dir.mktmpdir("project-rust-pipeline-spec-ruby")
      dirs.each { |dir| FileUtils.cp_r(File.join(GENERATED_ROOT, dir), File.join(ruby_snapshot, dir)) }

      run_project_rust!(domain, { "HECKS_PARSER" => "rust", "HECKS_CODEGEN" => "rust" })

      dirs.each do |dir|
        ruby_dir = File.join(ruby_snapshot, dir)
        rust_dir = File.join(GENERATED_ROOT, dir)

        ruby_files = files_in(ruby_dir)
        rust_files = files_in(rust_dir)
        expect(rust_files).to eq(ruby_files),
                              "#{dir}: the opt-in path's own file list differs from the default path's — " \
                              "ruby: #{ruby_files.inspect}, rust: #{rust_files.inspect}"

        (ruby_files - IGNORED_BASENAMES - CONTENT_EXEMPT_BASENAMES).each do |basename|
          ruby_text = File.read(File.join(ruby_dir, basename))
          rust_text = File.read(File.join(rust_dir, basename))

          expect(rust_text).to eq(ruby_text),
                               "#{dir}/#{basename}: the opt-in Rust path's output does not byte-match the default Ruby path's"
        end
      end
    ensure
      FileUtils.remove_entry(ruby_snapshot) if ruby_snapshot
    end
  end
end
