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
    scratch_directory :dir, "write-if-changed"

    it "leaves an unchanged file's mtime alone, so Cargo does not rebuild", :aggregate_failures do
      path = File.join(@dir, "a.rs")
      described_class.call(path, "fn a() {}\n")
      File.utime(Time.at(0), Time.at(0), path)

      expect(described_class.call(path, "fn a() {}\n")).to be(false)
      expect(File.mtime(path)).to eq(Time.at(0))
    end

    # Writes an orphan file the run never touches and records a kept one; returns both paths.
    def prune_with_orphan
      kept = File.join(@dir, "kept.rs")
      orphan = File.join(@dir, "orphan.rs")
      File.write(orphan, "")
      described_class.push_directory(@dir)
      described_class.call(kept, "x")
      [kept, orphan]
    end

    it "prunes a file the run never touched once the directory is closed", :aggregate_failures do
      kept, orphan = prune_with_orphan
      expect { described_class.pop_and_prune(@dir) }.to output(/pruned .*orphan\.rs/).to_stdout

      expect(File.exist?(orphan)).to be(false)
      expect(File.exist?(kept)).to be(true)
    end

    describe "an atomic write" do
      def write_atomically(name, text) = described_class.call(File.join(@dir, name), text, atomic: true)

      it "puts the bytes in place and leaves no temp file behind", :aggregate_failures do
        write_atomically("b.rs", "fn b() {}\n")

        expect(File.read(File.join(@dir, "b.rs"))).to eq("fn b() {}\n")
        expect(Dir.children(@dir)).to eq(["b.rs"])
      end

      it "keeps the permissions of the file it replaces" do
        File.write(File.join(@dir, "c.rs"), "fn old() {}\n")
        File.chmod(0o600, File.join(@dir, "c.rs"))
        write_atomically("c.rs", "fn new() {}\n")

        expect(File.stat(File.join(@dir, "c.rs")).mode & 0o777).to eq(0o600)
      end

      it "writes nothing, and keeps the mtime, when the bytes are the same", :aggregate_failures do
        File.write(File.join(@dir, "d.rs"), "fn same() {}\n")
        File.utime(Time.at(0), Time.at(0), File.join(@dir, "d.rs"))

        expect(write_atomically("d.rs", "fn same() {}\n")).to be(false)
        expect(File.mtime(File.join(@dir, "d.rs"))).to eq(Time.at(0))
      end

      # What a directory's `*` listing, the one a prune walks, holds when the rename happens.
      def listed_at_rename
        listed = nil
        allow(File).to receive(:rename).and_wrap_original do |rename, *args|
          listed = Dir.glob(File.join(@dir, "*"))
          rename.call(*args)
        end
        write_atomically("e.rs", "fn x() {}\n")
        listed
      end

      it "is not seen by the listing a directory's prune walks" do
        expect(listed_at_rename).to eq([])
      end
    end
  end
end
