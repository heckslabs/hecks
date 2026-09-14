require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "hecks/fuzzing"

# `Hecks::Fuzzing::RustGapManifest` — how the differential fuzzer learns
# which Ruby/Rust query divergences are declared, from the generator's own
# manifest.json rather than Rust's refusal wording — plus the two
# shrink-only checks on what the committed manifests declare.
RSpec.describe Hecks::Fuzzing::RustGapManifest do
  GAP_RUST_DIR = File.join(InMemoryDomain::ROOT, "rust")

  def write_module(root, name, entries, merged: true)
    dir = File.join(root, "src/generated", name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "manifest.json"), JSON.generate(entries))
    File.write(File.join(dir, "merged.rs"), "") if merged
  end

  def gap(kind, id, construct = "reference_hop_where")
    { "kind" => kind, "id" => id, "generated" => false, "gap_class" => "per_instance", "construct" => construct }
  end

  describe "the committed manifests" do
    let(:committed) { described_class.all_entries(GAP_RUST_DIR) }

    it "classify every recorded gap with a gap_class and a construct" do
      unclassified = committed.select do |entry|
        (entry["generated"] == false || entry["routed"] == false) &&
          (entry["gap_class"].to_s.empty? || entry["construct"].to_s.empty?)
      end
      expect(unclassified).to be_empty
    end

    # THE RATCHET. `structural_refusal_boundary` may only name construct
    # families some committed domain really leaves ungenerated. When codegen
    # closes the last instance of a family, the regenerated manifests stop
    # declaring it and this fails until the family is removed from
    # qa/settings.yml — so the boundary can only shrink.
    it "admit no structural_refusal_boundary family that no committed manifest declares not generated" do
      declared = committed.select { |e| described_class::TOLERABLE_KINDS.include?(e["kind"]) && e["generated"] == false }
                          .to_set { |e| e["construct"] }
      boundary = Hecks::Fuzzing::QaSettings.load.structural_refusal_boundary.map(&:to_s)

      expect(boundary - declared.to_a).to be_empty,
                                          "qa/settings.yml structural_refusal_boundary names " \
                                          "#{(boundary - declared.to_a).inspect}, which no committed " \
                                          "rust/src/generated/*/manifest.json declares — remove them " \
                                          "(declared families: #{declared.to_a.sort.inspect})"
    end
  end

  describe ".for_binary" do
    it "reads the rust dir and feature off a pinned conformance binary path" do
      gaps = described_class.for_binary(File.join(GAP_RUST_DIR, "target/debug/rust-banking"))
      expect(gaps.feature).to eq("banking")
      expect(gaps.not_generated("Banking::Account.LedgerEntry.Reversed"))
        .to include("gap_class" => "whole_kind", "construct" => "entity_query")
    end

    it "refuses a path that isn't a pinned binary rather than guess a manifest" do
      expect { described_class.for_binary("/usr/bin/true") }.to raise_error(ArgumentError, /pinned conformance binary/)
    end
  end

  describe "#not_generated" do
    it "declares only query and read-model verbs the manifest marks generated: false" do
      Dir.mktmpdir do |root|
        write_module(root, "shop", [
                       gap("query", "Shop::Order.ByHop"),
                       gap("command", "Shop::Order.Place", "optional_source"),
                       { "kind" => "query", "id" => "Shop::Order.Open", "generated" => true }
                     ])
        gaps = described_class.new(rust_dir: root, feature: "shop")

        expect(gaps.not_generated?("Shop::Order.ByHop")).to be(true)
        expect(gaps.not_generated?("Shop::Order.Open")).to be(false)
        expect(gaps.not_generated?("Shop::Order.Place")).to be(false)
        expect(gaps.not_generated?({ "aggregate" => "Shop::Order" })).to be(false)
      end
    end

    it "answers a read model under both wire spellings kernel::read_model::find accepts" do
      Dir.mktmpdir do |root|
        write_module(root, "shop", [gap("read_model", "Shop::FlaggedOrderCount", "rootless")])
        gaps = described_class.new(rust_dir: root, feature: "shop")

        expect(gaps.not_generated_verbs).to eq(Set["Shop.FlaggedOrderCount", "Shop.flagged_order_count"])
      end
    end

    it "includes shared framework chapters but not another domain's own module" do
      Dir.mktmpdir do |root|
        write_module(root, "shop", [])
        write_module(root, "governance", [gap("query", "Governance::Role.Hop")], merged: false)
        write_module(root, "other", [gap("query", "Other::Thing.Hop")])
        gaps = described_class.new(rust_dir: root, feature: "shop")

        expect(gaps.not_generated_verbs).to eq(Set["Governance::Role.Hop"])
      end
    end

    it "tolerates nothing when the binary's crate carries no manifest at all" do
      Dir.mktmpdir do |root|
        expect(described_class.new(rust_dir: root, feature: "shop").not_generated_verbs).to be_empty
      end
    end
  end
end
