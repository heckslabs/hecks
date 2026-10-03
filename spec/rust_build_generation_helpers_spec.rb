# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/rust_build/append_optionals"
require "hecks/rust_build/domain_name"
require "hecks/rust_build/rust_literal"
require "hecks/rust_build/write_if_changed"

# The helpers `hecks project_rust` uses around `hecks-codegen`: they replaced what lived in
# `rust/project`, which the codegen-backed path no longer loads.
RSpec.describe "hecks project_rust generation helpers" do
  describe Hecks::RustBuild::RustLiteral do
    it "escapes what Rust's string grammar needs and nothing else" do
      expect(described_class.string("a\"b\\c\nd\te\rf — é")).to eq("\"a\\\"b\\\\c\\nd\\te\\rf — é\"")
    end

    it "writes other control characters as Rust unicode escapes, never Ruby's" do
      expect(described_class.string("x\u0001\u007F")).to eq("\"x\\u{1}\\u{7f}\"")
    end
  end

  describe Hecks::RustBuild::DomainName do
    it "accepts a plain lowercase identifier" do
      expect(described_class.valid?("pizzas")).to be(true)
    end

    it "refuses a name that is not an identifier, a Rust keyword, or a reserved Cargo key" do
      expect(%w[Pizzas 9lives has-dash fn default].map { |name| described_class.valid?(name) }).to all(be(false))
    end

    it "lists the Cargo keys it reserves" do
      expect(described_class::CARGO_RESERVED).to include("default")
    end
  end

  describe Hecks::RustBuild::AppendOptionals do
    def ir(argument_optional:)
      { aggregates: [{
        name:          "Order",
        attributes:    [{ name: "lines", type: "Line", list: true }],
        entities:      [],
        value_objects: [{ name: "Line", attributes: [{ name: "note", type: "String" }] }],
        commands:      [{
          name:       "AddLine",
          attributes: [{ name: "note", type: "String", optional: argument_optional }],
          mutations:  [{ op: "append", target: "lines", fields: { "note" => ":note" } }]
        }]
      }] }
    end

    it "marks an appended element's field optional when its source argument is optional" do
      marked = described_class.mark(ir(argument_optional: true))

      expect(marked[:aggregates].first[:value_objects].first[:attributes].first[:optional]).to be(true)
    end

    it "leaves the field alone when the argument is required" do
      marked = described_class.mark(ir(argument_optional: false))

      expect(marked[:aggregates].first[:value_objects].first[:attributes].first).not_to have_key(:optional)
    end

    it "prefers an aggregate's own entity over a domain-wide value object of the same name" do
      aggregate = { entities: [{ name: "Line", attributes: [] }] }

      expect(described_class.element(aggregate, "Line", "Line" => { name: "Line", attributes: [] }))
        .to equal(aggregate[:entities].first)
    end
  end

  describe Hecks::RustBuild::WriteIfChanged do
    around do |example|
      Dir.mktmpdir("write-if-changed") do |dir|
        @dir = dir
        example.run
      end
    end

    it "leaves an unchanged file's mtime alone, so Cargo does not rebuild" do
      path = File.join(@dir, "a.rs")
      described_class.call(path, "fn a() {}\n")
      File.utime(Time.at(0), Time.at(0), path)

      expect(described_class.call(path, "fn a() {}\n")).to be(false)
      expect(File.mtime(path)).to eq(Time.at(0))
    end

    it "prunes a file the run never touched once the directory is closed" do
      kept = File.join(@dir, "kept.rs")
      orphan = File.join(@dir, "orphan.rs")
      File.write(orphan, "")
      described_class.push_directory(@dir)
      described_class.call(kept, "x")
      expect { described_class.pop_and_prune(@dir) }.to output(/pruned .*orphan\.rs/).to_stdout

      expect(File.exist?(orphan)).to be(false)
      expect(File.exist?(kept)).to be(true)
    end
  end
end
