require "spec_helper"
require "tmpdir"
require_relative "support/booted_source"

# A number in a rule reads as Ruby reads it: `900_000` is nine hundred thousand, whether the
# bluebook is declared inline or loaded from its file through hecks-parse.
RSpec.describe "a number with digit separators in a rule" do
  TIMERS_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "SeparatedTimers" do
      aggregate "Timer" do
        identified_by :tag
        value_object("Tag")    { attribute :value, String }
        value_object("Moment") { attribute :value, Integer }
        attribute :tag, Tag
        attribute :at, Moment, optional: true

        command "Start" do
          attribute :tag, Tag
          attribute :at, Moment
          given("it starts within fifteen minutes") { at.value < 900_000 }
          given("it starts after the window opens") { at.value >= 1_000.5 }
          sets :tag
          sets :at
          emits "Started"
        end
      end
    end
  BLUEBOOK

  def memory_hecksagon = Hecks.hecksagon("SeparatedTimers") { SeparatedTimers::Timer.persisted_by("Memory") }

  # The domain declared inline, its rules parsed by the Ruby runtime's own expression grammar.
  def inline_runtime = BootedSource.boot(TIMERS_SOURCE) { memory_hecksagon }

  # The domain loaded from its file, its rules parsed by hecks-parse.
  def loaded_runtime
    Dir.mktmpdir("separated-timers") do |dir|
      path = File.join(dir, "separated_timers.bluebook")
      File.write(path, TIMERS_SOURCE)
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) { boot_from(path) }
      registry.verify!
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end
  end

  def boot_from(path)
    MemoryPorts.load!
    load_bluebook_files(path)
    memory_hecksagon
  end

  def start(runtime, tag, moment)
    runtime.dispatch_flat("SeparatedTimers::Timer.Start", tag: { value: tag }, at: { value: moment })
  end

  { "declared inline" => :inline_runtime, "loaded from its file" => :loaded_runtime }.each do |how, boot|
    context "when #{how}" do
      let(:runtime) { send(boot) }

      it "accepts a moment under the separated limit" do
        expect(start(runtime, "a", 899_999).instance.state[:at][:value]).to eq(899_999)
      end

      it "refuses a moment at the separated limit by the rule's own words" do
        expect { start(runtime, "b", 900_000) }
          .to raise_error(Hecks::Runtime::GivenNotMet, /within fifteen minutes/)
      end

      it "reads a separated decimal too" do
        expect { start(runtime, "c", 1_000) }
          .to raise_error(Hecks::Runtime::GivenNotMet, /after the window opens/)
      end
    end
  end
end
