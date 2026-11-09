require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/rust_build"
require "hecks/rust_build/conformance"

# Where a conformance run looks for the native binary (`native`): the directory named by hand,
# else the linked worktree's own slot below the shared target (where `NativeBuild` builds), else
# the workspace's own `target/`.
RSpec.describe Hecks::RustBuild::Conformance do
  let(:checkout) { Dir.mktmpdir("conformance_checkout") }
  let(:rust) { File.join(checkout, "rust") }
  let(:slot) { File.join(checkout, "shared-target", Hecks::RustBuild::SessionBuild.slug(checkout)) }

  before do
    FileUtils.mkdir_p([File.join(checkout, "lib/hecks/hecks"), rust])
    File.write(File.join(checkout, ".git"), "gitdir: elsewhere")
    File.write(File.join(checkout, Hecks::RustBuild::SessionBuild::WORLD), <<~RUBY)
      Hecks.world "Tickets" do
        session_environment "Sessions", cargo_target_dir: "#{File.join(checkout, "shared-target")}", nice: 7
      end
    RUBY
    Hecks::RustBuild::SessionBuild.reset!
    allow(Hecks::RustBuild).to receive(:rust_dir).and_return(rust)
    stub_const("ENV", ENV.to_h.except("CARGO_TARGET_DIR"))
  end

  after do
    Hecks::RustBuild::SessionBuild.reset!
    FileUtils.rm_rf(checkout)
  end

  def binary_in(dir, profile = "debug")
    path = File.join(dir, profile, "rust")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "binary")
    File.chmod(0o755, path)
    path
  end

  it "looks in the worktree's own slot first and then in the workspace's target", :aggregate_failures do
    expect(described_class.send(:target_dirs)).to eq([slot, File.join(rust, "target")])
    expect(described_class.send(:native_binary)).to be_nil
  end

  it "finds a binary built into the slot, with no CARGO_TARGET_DIR set" do
    built = binary_in(slot)

    expect(described_class.send(:native_binary)).to eq(built)
  end

  it "finds one built into the workspace's own target by hand" do
    built = binary_in(File.join(rust, "target"), "release")

    expect(described_class.send(:native_binary)).to eq(built)
  end

  it "looks in a relative directory named by hand as Cargo does, from the workspace" do
    stub_const("ENV", ENV.to_h.merge("CARGO_TARGET_DIR" => "target-test"))

    expect(described_class.send(:target_dirs)).to include(File.join(rust, "target-test"))
  end
end
