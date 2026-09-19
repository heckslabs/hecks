require "spec_helper"
require "json"
require "tmpdir"
require "open3"
require_relative "../rust/project"
require_relative "fixtures/codegen_manifest/gap_families"

# **The coverage manifest, both generators**.
#
# `bin/rust_coverage` and the differential fuzzer read each gap's
# `construct` (and people read its `reason`) out of
# `rust/src/generated/<domain>/manifest.json`. This holds `hecks-codegen`'s
# `manifest.json` (rust/codegen/src/manifest.rs) byte-identical to
# `RustProjection::DomainGenerator.call`'s own, for every manifest-mode
# domain — every directory under rust/src/generated that carries a
# committed `manifest.json` — plus a copy of banking with every construct
# family planted (the corpus itself generates everything, so its manifests
# carry no gaps to compare).
#
# Both generators read the same IR: the committed `ir.json`. Ruby's
# `DomainGenerator.call` runs first (its derivation passes,
# `mark_append_optional_fields!`/`derive_reverses_mutations!`, are
# idempotent on an already-derived `ir.json`), then that same Hash is
# written out for `hecks-codegen domain` — the identical order
# `spec/codegen_parity_spec.rb` uses. This compares the two generators,
# not the committed tree's freshness (CI's drift check owns that).
RSpec.describe "Rust codegen manifest parity (hecks-codegen manifest.json)", :io do
  MANIFEST_PARITY_CODEGEN_DIR = File.expand_path("../rust/codegen", __dir__)
  MANIFEST_PARITY_CODEGEN_BINARY = File.join(MANIFEST_PARITY_CODEGEN_DIR, "target", "debug", "hecks-codegen")
  MANIFEST_PARITY_GENERATED_ROOT = File.expand_path("../rust/src/generated", __dir__)

  MANIFEST_MODE_DOMAINS = Dir.glob(File.join(MANIFEST_PARITY_GENERATED_ROOT, "*", "manifest.json"))
                             .map { |path| File.basename(File.dirname(path)) }
                             .sort
                             .freeze

  # domain => reason the two manifests still differ. A mismatch for any
  # domain not listed fails below; an entry here whose manifests now
  # match fails too, so this list can only ever shrink honestly.
  MANIFEST_KNOWN_GAPS = {}.freeze

  before(:context) do
    built = system("cargo", "build", chdir: MANIFEST_PARITY_CODEGEN_DIR, out: File::NULL, err: File::NULL)
    raise "cargo build failed for rust/codegen — run `cargo build` there directly to see why" unless built
  end

  def committed_ir(name)
    JSON.parse(File.read(File.join(MANIFEST_PARITY_GENERATED_ROOT, name, "ir.json")), symbolize_names: true)
  end

  # [ruby manifest.json bytes, rust manifest.json bytes] for `ir`.
  def both_manifests(domain_ir, name)
    Dir.mktmpdir do |tmp|
      ruby_dir = File.join(tmp, "ruby")
      rust_dir = File.join(tmp, "rust")
      RustProjection::DomainGenerator.call(domain_ir, name, ruby_dir, name)

      ir_json_path = File.join(tmp, "ir.json")
      File.write(ir_json_path, JSON.pretty_generate(domain_ir))
      stdout, status = Open3.capture2(MANIFEST_PARITY_CODEGEN_BINARY, "domain", ir_json_path, name, name, rust_dir)
      expect(status.success?).to be(true), "hecks-codegen domain failed for #{name}:\n#{stdout}"

      [File.binread(File.join(ruby_dir, "manifest.json")), File.binread(File.join(rust_dir, "manifest.json"))]
    end
  end

  # RSpec's own diff renders non-ASCII bytes as `???`, which hides what
  # actually differs — this names the first differing byte instead.
  def first_difference(ruby_manifest, rust_manifest)
    offset = ruby_manifest.bytes.zip(rust_manifest.bytes).index { |a, b| a != b } ||
             [ruby_manifest.bytesize, rust_manifest.bytesize].min
    window = ->(text) { text.byteslice([offset - 80, 0].max, 160).dup.force_encoding(Encoding::UTF_8).scrub.inspect }
    "first difference at byte #{offset} — ruby: #{window.call(ruby_manifest)}, rust: #{window.call(rust_manifest)}"
  end

  it "finds the manifest-mode domains to compare" do
    expect(MANIFEST_MODE_DOMAINS).not_to be_empty
    expect(MANIFEST_KNOWN_GAPS.keys - MANIFEST_MODE_DOMAINS).to be_empty
  end

  MANIFEST_MODE_DOMAINS.each do |name|
    it "#{name}: hecks-codegen's manifest.json is byte-identical to Ruby's DomainGenerator.call" do
      ruby_manifest, rust_manifest = both_manifests(committed_ir(name), name)

      if MANIFEST_KNOWN_GAPS.key?(name)
        expect(rust_manifest).not_to eq(ruby_manifest),
                                     "#{name}: manifests now match — remove it from MANIFEST_KNOWN_GAPS"
      else
        expect(rust_manifest).to eq(ruby_manifest),
                                 "#{name}: hecks-codegen's manifest.json differs from Ruby's — " \
                                 "#{first_difference(ruby_manifest, rust_manifest)}"
      end
    end
  end

  it "every planted construct family: both generators record it, byte-identically" do
    ruby_manifest, rust_manifest = both_manifests(ManifestGapFamilies.call(committed_ir("banking")), "gap_families")

    expect(rust_manifest).to eq(ruby_manifest),
                             "hecks-codegen's manifest.json differs from Ruby's for the planted gaps — " \
                             "#{first_difference(ruby_manifest, rust_manifest)}"

    # A copy: `JSON.parse` re-tags its source String's encoding in place,
    # which would make the byte-identical manifests above compare unequal.
    recorded = JSON.parse(ruby_manifest.dup).filter_map { |entry| entry["construct"] }.uniq
    expect(ManifestGapFamilies::CONSTRUCTS - recorded).to be_empty, "planted families no generator recorded"
  end
end
