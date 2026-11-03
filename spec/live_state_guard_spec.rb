require "spec_helper"
require "tmpdir"

# No spec writes the owner's event tap or the checkout's red flag. The run points a child's tap at
# its own temporary file, the Memory overlay switches the tap off in this process, the runtime's
# tap and the flag's marker refuse the live paths by name, and a flag that moved during an example
# fails it.
RSpec.describe LiveStateGuard do
  it "points the tap of a child process at the run's temporary file" do
    expect(ENV.fetch("HECKS_EVENT_TAP")).to eq(File.join(EVENT_TAP_SPEC_DIR, "events.jsonl"))
  end

  it "refuses a tap on the live event log" do
    expect { Hecks::Runtime::EventTap.new(path: described_class.tap_path) }
      .to raise_error(described_class::Violation, /live event tap/)
  end

  it "refuses the checkout's own red flag" do
    expect { Hecks::Adapters::RedFlagMarker.new(described_class.git_dir) }
      .to raise_error(described_class::Violation, /checkout's red flag/)
  end

  it "refuses a worktree's red flag, which is the checkout's" do
    expect { Hecks::Adapters::RedFlagMarker.new(File.join(described_class.git_dir, "worktrees", "x")) }
      .to raise_error(described_class::Violation, /checkout's red flag/)
  end

  it "reads a temp directory as outside the checkout", :aggregate_failures do
    expect(described_class.checkout?(Dir.tmpdir)).to be(false)
    expect(described_class.checkout?(described_class.git_dir)).to be(true)
  end

  it "switches the tap off when the Hecks domain boots for a spec" do
    registry = boot_hecks_in_memory.registry

    expect(registry.world("Hecks").for_verb("event_log")[:path].to_s).to eq("")
  end

  it "installs no tap on the booted registry" do
    expect(boot_hecks_in_memory.registry.event_log.observer).to be_nil
  end

  describe described_class::Watch do
    scratch_directory :dir

    it "names a file that moved since the snapshot" do
      file = File.join(@dir, "hecks-red-flag.json")
      watch = described_class.new([file])
      before = watch.snapshot
      File.write(file, "{}\n")

      expect(watch.changed(before)).to eq([file])
    end

    it "names nothing when the files stayed as they were" do
      file = File.join(@dir, "hecks-red-flag.json")
      File.write(file, "{}\n")
      watch = described_class.new([file])

      expect(watch.changed(watch.snapshot)).to eq([])
    end
  end
end
