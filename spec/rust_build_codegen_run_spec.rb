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

  scratch_directory :dir, "codegen-run"

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

  # The modules `hecks-codegen full` was asked for, with cargo and the binary stubbed.
  def generated_modules(meta)
    run = described_class.new(rust_dir: @dir, out_root: File.join(@dir, "out"), meta: meta, declarations: [],
                              target: described_class::Declaration.new("chess", "examples/chess", {}))
    commands = []
    allow(run).to receive(:system) { |*command, **| commands << command }.and_return(true)
    run.call
    commands.reject { |command| command.first == "cargo" }.map { |command| command[3] }
  end

  describe "#call" do
    it "generates the self-hosted language's own module beside the domain's" do
      expect(generated_modules({})).to eq(%w[meta chess])
    end

    it "leaves the language's module as an earlier run wrote it when it is given none" do
      expect(generated_modules(nil)).to eq(%w[chess])
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
