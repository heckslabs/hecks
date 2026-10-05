require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"
require "open3"
require_relative "fixtures/codegen_manifest/gap_families"

# The manifest hecks-codegen writes for a banking copy with one ungeneratable construct planted
# per skip family, held to a frozen snapshot. It stands where the Ruby-versus-Rust manifest
# comparison stood, now that hecks-codegen is the only generator (ADR 0086): every corpus
# domain's manifest is diffed by `hecks regenerate_corpus --check`, and this covers the families
# no corpus domain has. Regenerate with GOLDEN=rewrite only when a reason string really changed;
# `bin/rust_coverage`'s allowlist cites them, so read the diff first.
RSpec.describe "hecks-codegen manifest for every planted construct family", :io do
  PLANTED_CODEGEN_DIR = File.expand_path("../rust/codegen", __dir__)
  PLANTED_CODEGEN_BINARY = File.join(PLANTED_CODEGEN_DIR, "target", "debug", "hecks-codegen")
  PLANTED_BANKING_IR = File.expand_path("../rust/src/generated/banking/ir.json", __dir__)
  PLANTED_GOLDEN = File.expand_path("golden/codegen_manifest/gap_families.json", __dir__)

  before(:context) do
    built = system("cargo", "build", chdir: PLANTED_CODEGEN_DIR, out: File::NULL, err: File::NULL)
    raise "cargo build failed for rust/codegen — run `cargo build` there directly to see why" unless built
  end

  def planted_manifest
    ir = JSON.parse(File.read(PLANTED_BANKING_IR), symbolize_names: true)
    planted = ManifestGapFamilies.call(ir)

    Dir.mktmpdir do |tmp|
      ir_path = File.join(tmp, "ir.json")
      File.write(ir_path, JSON.pretty_generate(planted))
      out_dir = File.join(tmp, "out")
      stdout, status = Open3.capture2(PLANTED_CODEGEN_BINARY, "domain", ir_path, "gap_families", "gap_families", out_dir)
      expect(status.success?).to be(true), "hecks-codegen domain failed for the planted gaps:\n#{stdout}"
      File.read(File.join(out_dir, "manifest.json"), encoding: Encoding::UTF_8)
    end
  end

  it "records every planted family with the frozen reason" do
    manifest = planted_manifest
    if ENV["GOLDEN"] == "rewrite"
      FileUtils.mkdir_p(File.dirname(PLANTED_GOLDEN))
      File.write(PLANTED_GOLDEN, manifest)
    end

    expect(File.exist?(PLANTED_GOLDEN)).to be(true), "no frozen manifest — run GOLDEN=rewrite to record it"
    expect(manifest).to eq(File.read(PLANTED_GOLDEN, encoding: Encoding::UTF_8)), "the planted-gap manifest changed — read the diff, then GOLDEN=rewrite"
  end

  it "plants a construct in every family it names" do
    # A copy: `JSON.parse` re-tags its source String's encoding in place.
    recorded = JSON.parse(planted_manifest.dup).filter_map { |entry| entry["construct"] }.uniq

    expect(ManifestGapFamilies::CONSTRUCTS - recorded).to be_empty, "planted families no generator recorded"
  end
end
