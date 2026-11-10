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

  describe "a build whose binary is run afterwards" do
    let(:own) { File.join(shared, described_class.slug(root)) }

    it "takes a directory of the worktree's own below the shared one" do
      expect(described_class.environment(root: root, base: no_target, binary: true)).to eq("CARGO_TARGET_DIR" => own)
    end

    it "replaces the shared directory a dispatched session inherits" do
      inherited = { "CARGO_TARGET_DIR" => shared }

      expect(described_class.environment(root: root, base: inherited, binary: true)).to eq("CARGO_TARGET_DIR" => own)
    end

    it "leaves a directory named by hand alone" do
      expect(described_class.environment(root: root, base: { "CARGO_TARGET_DIR" => "/own" }, binary: true)).to eq({})
    end

    it "leaves the shared directory a test build inherits alone" do
      expect(described_class.environment(root: root, base: { "CARGO_TARGET_DIR" => shared })).to eq({})
    end

    it "records the checkout that owns the slot", :aggregate_failures do
      described_class.environment(root: root, base: no_target, binary: true)

      expect(File.read(File.join(own, described_class::OWNER))).to eq(File.realpath(root))
    end

    it "gives a native build the worktree's own slot when it inherits the shared directory" do
      expect(described_class.binary_dir(root: root, base: { "CARGO_TARGET_DIR" => shared })).to eq(own)
    end

    it "gives a native build a directory named by hand, not the shared one" do
      expect(described_class.binary_dir(root: root, base: { "CARGO_TARGET_DIR" => "/own" })).to eq("/own")
    end

    it "takes a relative directory named by hand from the directory Cargo runs in, as Cargo does" do
      named = described_class.binary_dir(root: root, base: { "CARGO_TARGET_DIR" => "target-test" }, relative_to: "/ws/rust/host")

      expect(named).to eq("/ws/rust/host/target-test")
    end

    it "makes nothing when it only looks up a directory", :aggregate_failures do
      described_class.target_dir(root: root, binary: true)
      described_class.binary_dir(root: root, base: no_target)

      expect(File.exist?(own)).to be(false)
    end

    it "claims a slot for the build that is about to write to it, and no other directory", :aggregate_failures do
      described_class.claim_slot(own, root)
      described_class.claim_slot(File.join(root, "rust", "target"), root)

      expect(File.exist?(File.join(own, described_class::OWNER))).to be(true)
      expect(File.exist?(File.join(root, "rust", "target"))).to be(false)
    end

    it "gives a native build in a checkout that is not a linked worktree its own target directory" do
      FileUtils.rm(File.join(root, ".git"))

      expect(described_class.binary_dir(root: root, base: no_target)).to be_nil
    end

    it "names the same directory for one checkout however its path is spelled" do
      expect(described_class.slug("#{root}/")).to eq(described_class.slug(root))
    end

    it "names a different directory for another checkout" do
      other = Dir.mktmpdir("session-build")

      expect(described_class.slug(other)).not_to eq(described_class.slug(root))
    ensure
      FileUtils.remove_entry(other)
    end

    it "names a directory ending in the checkout's name and eight hex digits" do
      expect(described_class.slug(root)).to match(/\A#{Regexp.escape(File.basename(root))}-\h{8}\z/)
    end
  end

  describe "the checkout a build belongs to" do
    it "is the nearest directory above the build with a .git" do
      crate = File.join(root, "rust", "codegen")
      FileUtils.mkdir_p(crate)

      expect(described_class.root_of(crate)).to eq(File.expand_path(root))
    end

    it "is the checkout this code runs from when nothing above the path names one" do
      expect(described_class.root_of("/")).to eq(Hecks::RustBuild::ROOT)
    end

    it "reads the world's directory for a checkout that is not a linked worktree" do
      FileUtils.rm(File.join(root, ".git"))

      expect(described_class.declared_target_dir(root: root)).to eq(shared)
    end
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

  describe "a world that cannot be read" do
    before do
      File.write(File.join(root, described_class::WORLD), "this is not ruby (")
      allow(Hecks::RustBuild::WorldRows).to receive(:warn)
    end

    it "adds nothing" do
      expect(described_class.environment(root: root, base: no_target)).to eq({})
    end

    it "names the world it could not read and why" do
      described_class.environment(root: root, base: no_target)
      expect(described_class.unreadable_world(root)).to include("tickets.world: SyntaxError")
    end

    it "warns that the settings are left at their defaults" do
      described_class.environment(root: root, base: no_target)
      expect(Hecks::RustBuild::WorldRows).to have_received(:warn).with(/could not be read/).once
    end

    it "keeps no failure as the answer, so a fixed world is read the next time", :aggregate_failures do
      described_class.environment(root: root, base: no_target)
      File.write(File.join(root, described_class::WORLD), %(Hecks.world("Tickets") { session_environment "S", nice: 3 }))
      expect(described_class.command(%w[cargo build], root: root)).to eq(%w[nice -n 3 cargo build])
      expect(described_class.unreadable_world(root)).to be_nil
    end
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

    it "follows the workspace it builds in, not the checkout running the code" do
      stub_const("Hecks::RustBuild::ROOT", "/running-checkout")
      Hecks::RustBuild.command!("cargo", "build", chdir: File.join(root, "rust"))

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

    it "builds a binary the worktree runs into a directory of its own below the shared one" do
      stub_const("ENV", ENV.to_h.except("CARGO_TARGET_DIR"))
      host = File.join(root, "rust/host")

      expect(Hecks::RustBuild::TargetDir.for(host, root: root, binary: true)).to eq(File.join(shared, described_class.slug(root)))
    end

    it "builds a binary into its own directory even when the shared one is inherited" do
      stub_const("ENV", ENV.to_h.merge("CARGO_TARGET_DIR" => shared))
      host = File.join(root, "rust/host")

      expect(Hecks::RustBuild::TargetDir.for(host, root: root, binary: true)).to eq(File.join(shared, described_class.slug(root)))
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
