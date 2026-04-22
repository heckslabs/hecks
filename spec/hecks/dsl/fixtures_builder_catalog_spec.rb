# spec/hecks/dsl/fixtures_builder_catalog_spec.rb
#
# Contract for Hecks::DSL::FixturesBuilder's `schema:` kwarg — the
# i42 catalog-dialect surface. When an aggregate declares `schema:`,
# the builder collects the row-shape declaration into `FixturesFile#catalogs`
# keyed by aggregate name. When `schema:` is absent, the catalogs
# map stays empty — the pre-i42 shape.
#
# Parity contract (spec/parity/fixtures_parity_test.rb) owns the
# Ruby/Rust output diff. This spec owns the Ruby-side surface: what
# `schema:` accepts, how it normalizes, and what the builder returns.
#
# [antibody-exempt: spec for .fixtures DSL builder — the builder is
#  the Ruby half of the catalog-dialect parser pair; tests live
#  alongside the builder they protect.]
#
$LOAD_PATH.unshift File.expand_path("../../../../lib", __dir__)
require "hecks/dsl/fixtures_builder"

RSpec.describe Hecks::DSL::FixturesBuilder do
  describe "#aggregate with schema:" do
    it "records a normalized catalog schema keyed by aggregate name" do
      builder = described_class.new("Antibody")
      builder.aggregate("FlaggedExtension", schema: { ext: String }) do
      end

      file = builder.build
      expect(file.catalogs).to eq(
        "FlaggedExtension" => [{ name: "ext", type: "String" }],
      )
    end

    it "normalizes multiple attrs in declaration order" do
      builder = described_class.new("Antibody")
      builder.aggregate("ShebangMapping",
                        schema: { match: String, ext: String }) do
      end

      file = builder.build
      expect(file.catalogs["ShebangMapping"]).to eq([
        { name: "match", type: "String" },
        { name: "ext",   type: "String" },
      ])
    end

    it "leaves catalogs empty when schema: is omitted (pre-i42 shape)" do
      builder = described_class.new("Pizzas")
      builder.aggregate("Pizza") do
        # no schema:, no fixtures — still the pre-i42 shape
      end

      file = builder.build
      expect(file.catalogs).to eq({})
    end

    it "collects fixtures for a catalog aggregate alongside the schema" do
      builder = described_class.new("Antibody")
      builder.aggregate("FlaggedExtension", schema: { ext: String }) do
        fixture "Ruby", ext: "rb"
        fixture "Rust", ext: "rs"
      end

      file = builder.build
      expect(file.catalogs["FlaggedExtension"]).to eq([
        { name: "ext", type: "String" },
      ])
      expect(file.fixtures.size).to eq(2)
      expect(file.fixtures.map(&:name)).to eq(%w[Ruby Rust])
    end

    it "mixes plain aggregates and catalogs in one file" do
      builder = described_class.new("Mixed")
      builder.aggregate("Pizza") do
        # no schema — plain aggregate, fixtures resolve against bluebook
      end
      builder.aggregate("Color", schema: { hex: String, name: String }) do
        # schema — this is a catalog
      end

      file = builder.build
      expect(file.catalogs.keys).to eq(["Color"])
      expect(file.catalogs["Color"]).to eq([
        { name: "hex",  type: "String" },
        { name: "name", type: "String" },
      ])
    end
  end

  describe "FixturesFile equality" do
    it "takes catalogs into account" do
      a = Hecks::DSL::FixturesBuilder::FixturesFile.new(
        name: "X", fixtures: [], catalogs: { "C" => [{ name: "k", type: "String" }] },
      )
      b = Hecks::DSL::FixturesBuilder::FixturesFile.new(
        name: "X", fixtures: [], catalogs: { "C" => [{ name: "k", type: "String" }] },
      )
      c = Hecks::DSL::FixturesBuilder::FixturesFile.new(
        name: "X", fixtures: [], catalogs: {},
      )
      expect(a).to eq(b)
      expect(a).not_to eq(c)
    end
  end
end
