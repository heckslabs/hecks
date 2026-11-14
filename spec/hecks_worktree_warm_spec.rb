require "spec_helper"
require "fileutils"
require "rbconfig"
require "tmpdir"
require "hecks/hecks/adapters/delivery_library"
Hecks::Adapters::DeliveryLibrary.require("git_worktree_warm")

# A new worktree gets its resident started, from the worktree's own code, so its first
# launcher lines are served and not booted cold.
RSpec.describe Hecks::Adapters::GitWorktreeWarm do
  let(:root) { Dir.mktmpdir("hecks-warm") }
  let(:script) { File.join(root, "exe", "hecks") }

  def with_launcher
    FileUtils.mkdir_p([File.join(root, "exe"), File.join(root, "lib", "hecks")])
    File.write(script, "#!/bin/sh\n")
    FileUtils.chmod(0o755, script)
  end

  def residents_on
    previous = ENV.fetch("HECKS_NO_RESIDENT", nil)
    ENV.delete("HECKS_NO_RESIDENT")
    yield
  ensure
    previous ? ENV["HECKS_NO_RESIDENT"] = previous : ENV.delete("HECKS_NO_RESIDENT")
  end

  before do
    allow(Process).to receive(:spawn).and_return(4242)
    allow(Process).to receive(:detach)
  end

  after { FileUtils.remove_entry(root) }

  it "launches the worktree's resident and says it is starting" do
    with_launcher
    expect(residents_on { described_class.resident(root) }).to eq("starting")
  end

  it "runs the child from the worktree's own lib, with its own launcher", :aggregate_failures do
    with_launcher
    residents_on { described_class.resident(root) }
    expect(Process).to have_received(:spawn)
      .with(RbConfig.ruby, "--disable-gems", "-I", File.join(root, "lib"), "-e", anything, root, script,
            hash_including(pgroup: true))
  end

  it "gives the child a script that is valid Ruby" do
    expect { RubyVM::InstructionSequence.compile(described_class::START) }.not_to raise_error
  end

  it "does not wait for the child" do
    with_launcher
    residents_on { described_class.resident(root) }
    expect(Process).to have_received(:detach).with(4242)
  end

  it "starts nothing where residents are switched off" do
    with_launcher
    described_class.resident(root)
    expect(Process).not_to have_received(:spawn)
  end

  it "starts nothing for a worktree with no launcher" do
    residents_on { described_class.resident(root) }
    expect(Process).not_to have_received(:spawn)
  end

  it "answers nothing and fails nothing when the child cannot be launched" do
    with_launcher
    allow(Process).to receive(:spawn).and_raise(Errno::EACCES)
    expect(residents_on { described_class.resident(root) }).to be_nil
  end
end
