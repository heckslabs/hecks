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

  describe ".build" do
    let(:finished) { instance_double(Process::Status, success?: true) }
    let(:own) { { "CARGO_TARGET_DIR" => "/shared/target/tree-0123abcd" } }

    before do
      allow(Hecks::RustBuild::BuildLock).to receive(:hold).and_yield({})
      allow(Open3).to receive(:capture2e).and_return(["", finished])
      allow(Hecks::RustBuild::SessionBuild).to receive_messages(environment: own, command: %w[nice cargo build])
    end

    it "asks for the worktree's own target directory, the one the binary is then run from", :aggregate_failures do
      described_class.build(checkout_crate)

      expect(Hecks::RustBuild::SessionBuild).to have_received(:environment).with(hash_including(binary: true))
      expect(Open3).to have_received(:capture2e).with(own, "nice", "cargo", "build", chdir: checkout_crate)
    end
  end

  describe ".binary" do
    it "is in the crate's own target directory by default" do
      allow(Hecks::RustBuild::SessionBuild).to receive(:environment).and_return({})

      expect(described_class.binary(@dir, env: {})).to eq(File.join(checkout_crate, "target/debug/hecks-codegen"))
    end

    it "is in the worktree's own directory below the Tickets world's shared one, as the build puts it" do
      own = { "CARGO_TARGET_DIR" => "/shared/target/tree-0123abcd" }
      allow(Hecks::RustBuild::SessionBuild).to receive(:environment).with(hash_including(binary: true)).and_return(own)

      expect(described_class.binary(@dir, env: {})).to eq("/shared/target/tree-0123abcd/debug/hecks-codegen")
    end

    it "is under CARGO_TARGET_DIR when a build sets it, so nothing lands inside an installed gem" do
      env = { "CARGO_TARGET_DIR" => File.join(@dir, "target") }

      expect(described_class.binary(@dir, env: env)).to eq(File.join(@dir, "target/debug/hecks-codegen"))
    end
  end
end
