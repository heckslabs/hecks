require "spec_helper"
require "json"
require "tmpdir"
require "open3"
require_relative "../rust/project"

# THE COVERAGE MANIFEST, BOTH GENERATORS (ADR 0054 option 2, step B1).
#
# `bin/rust_coverage` reads `rust/src/generated/<domain>/manifest.json` and
# matches its ALLOWLIST regexes against each entry's `reason` text, so the
# reason strings are a contract. This holds `hecks-codegen`'s
# `manifest.json` (rust/codegen/src/manifest.rs) byte-identical to
# `RustProjection::DomainGenerator.call`'s own, for EVERY manifest-mode
# domain — every directory under rust/src/generated that carries a
# committed `manifest.json` — so `bin/rust_coverage` can run against either
# generator's output unchanged.
#
# Both generators read the SAME IR: the committed `ir.json`. Ruby's
# `DomainGenerator.call` runs first (its derivation passes,
# `mark_append_optional_fields!`/`derive_reverses_mutations!`, are
# idempotent on an already-derived `ir.json`), then that same Hash is
# written out for `hecks-codegen domain` — the identical order
# `spec/codegen_parity_spec.rb` uses. This compares the two GENERATORS,
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
  # domain NOT listed fails below; an entry here whose manifests now
  # match fails too, so this list can only ever shrink honestly.
  #
  # An entry belongs here only for a real divergence in the generators'
  # own skip decision, which the manifest merely reports — never for a
  # manifest-writer gap. Empty since B2 ported BUG#32's `remove` op
  # (corrections' Ledger.Void) into rust/codegen.
  MANIFEST_KNOWN_GAPS = {}.freeze

  before(:context) do
    built = system("cargo", "build", chdir: MANIFEST_PARITY_CODEGEN_DIR, out: File::NULL, err: File::NULL)
    raise "cargo build failed for rust/codegen — run `cargo build` there directly to see why" unless built
  end

  it "finds the manifest-mode domains to compare" do
    expect(MANIFEST_MODE_DOMAINS).not_to be_empty
    expect(MANIFEST_KNOWN_GAPS.keys - MANIFEST_MODE_DOMAINS).to be_empty
  end

  MANIFEST_MODE_DOMAINS.each do |name|
    it "#{name}: hecks-codegen's manifest.json is byte-identical to Ruby's DomainGenerator.call" do
      ir = JSON.parse(File.read(File.join(MANIFEST_PARITY_GENERATED_ROOT, name, "ir.json")), symbolize_names: true)

      Dir.mktmpdir do |tmp|
        ruby_dir = File.join(tmp, "ruby")
        rust_dir = File.join(tmp, "rust")
        RustProjection::DomainGenerator.call(ir, name, ruby_dir, name)

        ir_json_path = File.join(tmp, "ir.json")
        File.write(ir_json_path, JSON.pretty_generate(ir))
        stdout, status = Open3.capture2(MANIFEST_PARITY_CODEGEN_BINARY, "domain", ir_json_path, name, name, rust_dir)
        expect(status.success?).to be(true), "hecks-codegen domain failed for #{name}:\n#{stdout}"

        ruby_manifest = File.binread(File.join(ruby_dir, "manifest.json"))
        rust_manifest = File.binread(File.join(rust_dir, "manifest.json"))

        if MANIFEST_KNOWN_GAPS.key?(name)
          expect(rust_manifest).not_to eq(ruby_manifest),
                                       "#{name}: manifests now match — remove it from MANIFEST_KNOWN_GAPS"
        else
          expect(rust_manifest).to eq(ruby_manifest), "#{name}: hecks-codegen's manifest.json differs from Ruby's"
        end
      end
    end
  end
end
