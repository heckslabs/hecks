require "spec_helper"
require "tmpdir"
require "hecks/rust_build"
require "hecks/rust_build/target_dir"
require "hecks/hecks/adapters/shell"
require "hecks/hecks/adapters/codebase/cargo_tests"

# Every Rust build child reads the Tickets world's `session_environment` line: one shared Cargo
# target directory and a `nice` increment, the same ones a dispatched session starts with.
RSpec.describe Hecks::RustBuild::SessionBuild do
  let(:root) { Dir.mktmpdir("session-build") }
  let(:shared) { File.join(root, "shared-target") }
  let(:no_target) { {} }

  before do
    FileUtils.mkdir_p(File.join(root, "lib/hecks/hecks"))
    File.write(File.join(root, ".git"), "gitdir: elsewhere")
    File.write(File.join(root, described_class::WORLD), <<~RUBY)
      Hecks.world "Tickets" do
        session_environment "Sessions", cargo_target_dir: "#{shared}", nice: 7
      end
    RUBY
    described_class.reset!
  end

  after do
    described_class.reset!
    FileUtils.remove_entry(root)
  end

  it "reads the target directory from the world" do
    expect(described_class.environment(root: root, base: no_target)).to eq("CARGO_TARGET_DIR" => shared)
  end

  it "leaves a target directory the caller already named alone" do
    expect(described_class.environment(root: root, base: { "CARGO_TARGET_DIR" => "/elsewhere" })).to eq({})
  end

  it "puts the build under the world's nice increment" do
    expect(described_class.command(%w[cargo build], root: root)).to eq(%w[nice -n 7 cargo build])
  end

  it "adds nothing when the checkout has no world" do
    bare = Dir.mktmpdir("bare-checkout")
    File.write(File.join(bare, ".git"), "gitdir: elsewhere")

    expect(described_class.command(%w[cargo build], root: bare)).to eq(%w[cargo build])
  ensure
    FileUtils.remove_entry(bare)
  end

  it "leaves a checkout that is not a linked worktree alone" do
    FileUtils.rm(File.join(root, ".git"))

    expect(described_class.command(%w[cargo build], root: root)).to eq(%w[cargo build])
  end

  it "adds nothing when the world cannot be read" do
    File.write(File.join(root, described_class::WORLD), "this is not ruby (")

    expect(described_class.environment(root: root, base: no_target)).to eq({})
  end

  describe "the build commands" do
    before do
      stub_const("Hecks::RustBuild::ROOT", root)
      stub_const("ENV", ENV.to_h.except("CARGO_TARGET_DIR"))
      allow(Hecks::RustBuild).to receive(:system).and_return(true)
    end

    it "starts RustBuild.command! under the shared target directory and nice", :aggregate_failures do
      Hecks::RustBuild.command!("cargo", "build")

      expect(Hecks::RustBuild).to have_received(:system)
        .with(hash_including("CARGO_TARGET_DIR" => shared), "nice", "-n", "7", "cargo", "build", any_args)
    end

    it "lets a command's own environment win over the world's" do
      Hecks::RustBuild.command!("cargo", "build", env: { "CARGO_TARGET_DIR" => "/own" })

      expect(Hecks::RustBuild).to have_received(:system).with(hash_including("CARGO_TARGET_DIR" => "/own"), any_args)
    end
  end

  describe "Hecks::RustBuild::TargetDir" do
    let(:worktree) { Dir.mktmpdir("linked-worktree") }

    before { File.write(File.join(worktree, ".git"), "gitdir: elsewhere") }

    after { FileUtils.remove_entry(worktree) }

    it "builds a linked worktree into the world's shared directory" do
      stub_const("ENV", ENV.to_h.except("CARGO_TARGET_DIR"))
      FileUtils.mkdir_p(File.join(worktree, "lib/hecks/hecks"))
      FileUtils.cp(File.join(root, described_class::WORLD), File.join(worktree, described_class::WORLD))

      expect(Hecks::RustBuild::TargetDir.for(File.join(worktree, "rust/host"), root: worktree)).to eq(shared)
    end
  end

  describe "cargo tests" do
    let(:tree) { Struct.new(:root) { def path(*parts) = File.join(root, *parts) }.new(root) }
    let(:shell) { instance_double(Hecks::Adapters::Shell, capture: finished_result) }

    before { stub_const("ENV", ENV.to_h.except("CARGO_TARGET_DIR")) }

    def finished_result
      Hecks::Adapters::Shell::Result.new("", "", instance_double(Process::Status, success?: true))
    end

    it "runs the cargo child under the world's nice and target directory" do
      Hecks::Adapters::Codebase::CargoTests.run({ crate: "parser" }, tree, shell)

      expect(shell).to have_received(:capture)
        .with("nice", "-n", "7", "cargo", "test", env:   hash_including("CARGO_TARGET_DIR" => shared),
                                                  chdir: tree.path("rust/parser"))
    end
  end
end
