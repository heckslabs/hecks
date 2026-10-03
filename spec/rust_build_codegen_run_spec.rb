# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/rust_build"
require "hecks/rust_build/project_rust"

# Where `hecks project_rust` finds the `hecks-codegen` crate and its binary: in a checkout, in a
# copy of the packaged workspace (which must not build inside the installed gem), and in a scratch
# crate that holds only generated output.
RSpec.describe Hecks::RustBuild::ProjectRust::CodegenRun do
  let(:checkout_crate) { File.join(Hecks::RustBuild::ROOT, "rust/codegen") }

  around do |example|
    Dir.mktmpdir("codegen-run") do |dir|
      @dir = dir
      example.run
    end
  end

  describe ".crate_dir" do
    it "is the workspace's own crate when it carries one, as a packaged copy does" do
      FileUtils.mkdir_p(File.join(@dir, "codegen"))

      expect(described_class.crate_dir(@dir)).to eq(File.join(@dir, "codegen"))
    end

    it "falls back to the checkout's crate for a scratch crate with only generated output" do
      FileUtils.mkdir_p(File.join(@dir, "src/generated"))

      expect(described_class.crate_dir(@dir)).to eq(checkout_crate)
    end
  end

  describe ".binary" do
    it "is in the crate's own target directory by default" do
      expect(described_class.binary(@dir, env: {})).to eq(File.join(checkout_crate, "target/debug/hecks-codegen"))
    end

    it "is under CARGO_TARGET_DIR when a build sets it, so nothing lands inside an installed gem" do
      env = { "CARGO_TARGET_DIR" => File.join(@dir, "target") }

      expect(described_class.binary(@dir, env: env)).to eq(File.join(@dir, "target/debug/hecks-codegen"))
    end
  end
end
