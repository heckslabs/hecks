require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/main_integration"

# The launchd beat job runs at the priority the Hecks world declares: Standard, so macOS may put it
# and every process it starts on the performance cores, and no low-priority IO.
RSpec.describe "the beat job's priority" do
  let(:schedule_class) { Hecks::Adapters::MainIntegration::BeatSchedule }
  let(:priority_class) { Hecks::Adapters::MainIntegration::JobPriority }
  let(:home) { Dir.mktmpdir("hecks-beat-priority") }
  let(:defaults) { priority_class::DEFAULTS }

  after { FileUtils.remove_entry(home) }

  def plist_for(priority = nil)
    options = { root: "/train", home: home }
    options[:priority] = priority if priority
    schedule_class.new(**options).plist
  end

  it "runs the job at Standard QoS with no low-priority IO by default", :aggregate_failures do
    plist = plist_for
    expect(plist).to include("<key>ProcessType</key>\n  <string>Standard</string>")
    expect(plist).not_to include("Background", "LowPriorityIO")
  end

  it "keeps the declared nice increment", :aggregate_failures do
    expect(plist_for).to include("<key>Nice</key>\n  <integer>#{defaults[:nice]}</integer>")
    expect(plist_for(priority_class.new(nice: 3))).to include("<integer>3</integer>")
  end

  it "falls back to the defaults when no registry or world declares the job", :aggregate_failures do
    expect(priority_class.from(nil).to_h).to eq(defaults)
    expect(priority_class.from(instance_double(Hecks::Runtime::Registry, world: nil)).to_h).to eq(defaults)
  end

  it "reads the Hecks world's launchd_job setting" do
    world = Struct.new(:settings) { def for_verb(_verb) = settings }.new({ nice: 4 })
    registry = instance_double(Hecks::Runtime::Registry, world: world)
    expect(priority_class.from(registry).to_h[:nice]).to eq(4)
  end

  it "refuses a Background process type by name" do
    expect { priority_class.new(process_type: "Background") }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /Background/)
  end
end
