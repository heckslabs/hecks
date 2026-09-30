require "spec_helper"
require "json"
require "fileutils"
require "tmpdir"
require "open3"
require_relative "../rust/project"

# Holds hecks-codegen's whole-file domain output (aggregate .rs, registry.rs, mod.rs)
# byte-identical to Ruby's `DomainGenerator.call` for every corpus member.

# The cargo build lives in `before(:context)`: RSpec evaluates a group body even when
# `io: true` excludes its examples, so a body-level build would run on every suite.
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

  # Loads a domain the way hecks project_rust does, so the input cannot drift from the generator's.
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

  # `MetaValidator.grammar_registry` is the only door that sets @bootstrapping around the
  # self-hosted grammar's load, whose files reference types declared in later files.
  def self.meta_ir
    json_shaped(Hecks::Projector::Exporter.call(Hecks::Bluebook::MetaValidator.grammar_registry).fetch("Bluebook"))
  end

  # [member name, ir-loader lambda], derived from Hecks::Corpus rather than hand-listed.
  def self.corpus_member(name, source)
    [name, -> { domain_ir(source, Hecks::Corpus.chapter_name_of(Hecks::Corpus.bluebook_files(source) || source)) }]
  end

  CODEGEN_CORPUS_MEMBERS = [
    *Hecks::Corpus.rust_regen_order.map { |domain| corpus_member(domain.feature, Hecks::Corpus.bluebook_dir(domain.dir)) },
    *Hecks::Corpus.rust_framework_chapters.map do |stem|
      corpus_member(stem, File.join(Hecks::Corpus::ROOT, "lib/hecks/framework/bluebook/#{stem}.bluebook"))
    end,
    # A vendored package (ADR 0058) generated as a side effect of another domain's regen.
    *Hecks::Corpus.rust_vendored_chapters.map do |stem|
      member = Hecks::Corpus.members(:vendored).find { |m| m.stem == stem }
      corpus_member(stem, Hecks::Corpus.bluebook_dir(member.path))
    end,
    ["bluebook_language", -> { meta_ir }]
  ].freeze

  # Shrink-only: members whose Rust output still differs from Ruby's, with the owning bug.
  # Runs as RSpec `pending`, so a member that now matches fails until it is removed.
  CODEGEN_PENDING_MEMBERS = {}.freeze

  it "finds at least one real corpus member" do
    expect(CODEGEN_CORPUS_MEMBERS).not_to be_empty
  end

  it "pends only members it actually derives" do
    expect(CODEGEN_PENDING_MEMBERS.keys - CODEGEN_CORPUS_MEMBERS.map(&:first)).to be_empty
  end

  CODEGEN_CORPUS_MEMBERS.each do |name, ir_loader|
    it "#{name}: Rust hecks-codegen's FULL domain .rs output (every aggregate file + registry.rs + " \
       "mod.rs) is byte-identical to Ruby's" do
      pending CODEGEN_PENDING_MEMBERS.fetch(name) if CODEGEN_PENDING_MEMBERS.key?(name)
      ir = ir_loader.call

      Dir.mktmpdir do |tmp|
        ruby_dir = File.join(tmp, "ruby")
        rust_dir = File.join(tmp, "rust")

        # Also writes metadata.rs/ir.json/manifest.json into `ruby_dir`; those are not compared.
        RustProjection::DomainGenerator.call(ir, name, ruby_dir, name)

        ir_json_path = File.join(tmp, "ir.json")
        File.write(ir_json_path, JSON.pretty_generate(ir))
        stdout, status = Open3.capture2(CODEGEN_BINARY, "domain", ir_json_path, name, name, rust_dir)
        expect(status.success?).to be(true), "hecks-codegen domain failed for #{name}:\n#{stdout}"

        # Only what the crate generates: metadata.rs, ir.json and manifest.json are not ported.
        # mod.rs is compared with `DomainGenerator.call`, not the checked-in file
        # that hecks project_rust extends.
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

  # Mirrors `DomainGenerator.call`'s unsupported_attribute_types skip so basenames cannot drift.
  def generated_aggregate_basenames(payload)
    payload[:aggregates].filter_map do |aggregate|
      vo_by_name = aggregate[:value_objects].to_h { |vo| [vo[:name], vo] }
      next nil if RustProjection::Projector.unsupported_attribute_types(aggregate, vo_by_name).any?

      "#{aggregate[:name].downcase}.rs"
    end
  end
end
