# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/main_integration/local_overlay"
require "hecks/hecks/adapters/quieting"
require "hecks/hecks/adapters/dispatching"

# A merge window quiets the pipeline so a train merges without competing work. Opened, it pauses the
# fill by a record of its own (the owner's switch is never edited) and asks the `Quieting` port to
# stop what runs; closed, the fill runs again. The domain is the real one, booted in Memory; the
# adapter's two doers are stand-ins, so no session stops and no process ends.
RSpec.describe "a merge window" do
  let(:runtime) { boot_hecks_in_memory }
  let(:switched_on) do
    world = Object.new.tap { |held| held.define_singleton_method(:for_verb) { |_verb| { roll_forward: true } } }
    SimpleDelegator.new(runtime.registry).tap { |registry| registry.define_singleton_method(:world) { |_name| world } }
  end
  let(:settings) { Hecks::Adapters::Dispatching::Settings.new(switched_on) }
  let(:runs) do
    instance_double(Hecks::Adapters::Quieting::PipelineRuns, stop_all: { sessions: %w[s1 s2], items: ["a"] })
  end
  let(:trees) { instance_double(Hecks::Adapters::Quieting::LandingTrees, end_all: [4, 5, 6]) }

  def command(*words)
    quiet = Hecks::Adapters::Quieting.new(settings: { runs: runs, trees: trees })
    Hecks::Runtime::AdapterLookup.standing_in(->(_port, _asked) { quiet }) do
      Hecks::Adapters::Driving::CliRunner.call(runtime: runtime, argv: [*words, "--wait"], program: "hecks")
    end
  end

  def open_window = command("MergeWindow.open!", "run.value=w1", "reason.value=train", "opened_by.value=owner")

  def record
    registry = runtime.registry
    registry.repository("Hecks", registry.bluebook("Hecks").aggregate("MergeWindow")).all.first
  end

  it "lets the fill run while the owner's switch is on and no window is open" do
    expect(settings.roll_forward?).to be(true)
  end

  it "pauses the fill while a window is open, with the owner's switch still on" do
    open_window

    expect(settings.roll_forward?).to be(false)
  end

  it "records what quieting stopped, returned and ended" do
    open_window

    expect(record.quieted.value).to eq("stopped 2 pipeline sessions, returned 1 work items to the plan, " \
                                       "ended 3 landing processes; branches and commits kept")
  end

  it "lets the fill run again once the window is closed", :aggregate_failures do
    open_window
    command("MergeWindow.close!", "to=w1")

    expect(record.status).to eq("closed")
    expect(settings.roll_forward?).to be(true)
  end

  # A window is opened by one launcher call and closed by another, and the fill and the board read it
  # from processes of their own, so it has to be kept, not held in the memory of the call that opened it.
  it "is persisted by the overlay, so a later call can close it" do
    rows = Hecks::Adapters::MainIntegration::KeptRows.from_registry(boot_hecks_in_memory.registry)
    text = Hecks::Adapters::MainIntegration::LocalOverlay.new(Dir.pwd, rows, "train").text

    expect(text).to include("Hecks::MergeWindow.persisted_by(\"SqlitePersistence\")")
  end
end
