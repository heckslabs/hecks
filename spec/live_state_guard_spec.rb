require "spec_helper"

# No spec writes the owner's event tap. The run points a child's tap at its own temporary file,
# the Memory overlay switches the tap off in this process, and the runtime's tap refuses the live
# path by name.
RSpec.describe LiveStateGuard do
  it "points the tap of a child process at the run's temporary file" do
    expect(ENV.fetch("HECKS_EVENT_TAP")).to eq(File.join(EVENT_TAP_SPEC_DIR, "events.jsonl"))
  end

  it "refuses a tap on the live event log" do
    expect { Hecks::Runtime::EventTap.new(path: described_class.tap_path) }
      .to raise_error(described_class::Violation, /live event tap/)
  end

  it "switches the tap off when the Hecks domain boots for a spec" do
    registry = boot_hecks_in_memory.registry

    expect(registry.world("Hecks").for_verb("event_log")[:path].to_s).to eq("")
  end

  it "installs no tap on the booted registry" do
    expect(boot_hecks_in_memory.registry.event_log.observer).to be_nil
  end
end
