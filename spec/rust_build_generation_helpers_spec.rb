# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "hecks/rust_build/domain_name"
require "hecks/rust_build/write_if_changed"

# The helpers `hecks project_rust` uses around `hecks-codegen`. Marking the IR and writing its
# sidecars belong to `hecks-codegen` itself.
RSpec.describe "hecks project_rust generation helpers" do
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
