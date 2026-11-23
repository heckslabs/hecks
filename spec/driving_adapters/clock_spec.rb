require "spec_helper"
require "stringio"
require "tmpdir"
require "hecks/adapters/driving/clock"

# A clock declared in a hecksagon: parsed into the IR, admitted at boot, and run against a
# Memory domain on a fake clock, so no example sleeps (ADR 0184).
RSpec.describe "a clock, the driving adapter that dispatches a command on a schedule" do
  # A clock that reads a held time and moves it forward when asked to sleep. `jump` stands for a
  # machine that slept: each sleep moves the time that much further on.
  FakeTime = Struct.new(:now, :jump) do
    def sleep(seconds) = self.now += seconds + jump.to_i
  end

  def bluebook_text
    <<~RUBY
      Hecks.bluebook "Lending" do
        vision "Lend something out each morning."
        supporting

        aggregate "Loan" do
          description "A thing lent out."
          attribute :name, LoanName
          attribute :day,  LoanDay
          identified_by :name

          value_object "LoanName" do
            attribute :value, String, matches: :present
          end

          value_object "LoanDay" do
            attribute :value, String, pattern: '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
          end

          command "OpenLoan" do
            goal "Lend something out"
            attribute :name, LoanName
            attribute :day,  LoanDay
            sets :name
            sets :day
            emits "LoanOpened"
          end
        end
      end
    RUBY
  end

  MORNING = <<~RUBY.freeze
    clock "Morning" do
      cron "30 6 * * *", zone: "America/Phoenix"
      dispatch "Loan.OpenLoan", with: { name: :firing_id, day: :fire_date }
    end
  RUBY

  # Boots the Lending domain under a hecksagon holding `wiring`.
  def boot_with(wiring)
    Dir.mktmpdir("clock") do |dir|
      File.write(File.join(dir, "lending.bluebook"), bluebook_text)
      File.write(File.join(dir, "lending.hecksagon"),
                 "Hecks.hecksagon \"Lending\" do\n  Lending::Loan.persisted_by(\"Memory\")\n#{wiring}\nend\n")
      return Hecks.boot(dir, install_driving: false)
    end
  end

  let(:log) { StringIO.new }
  let(:morning) { Time.utc(2026, 11, 23, 13, 29, 30).to_i }

  before { allow(Hecks::Storehouse).to receive(:record!) }

  def runner(runtime, time) = Hecks::Adapters::Driving::Clock.runner(runtime, "Morning", time: time, log: log)

  it "parses into the hecksagon's IR with its trigger, zone, command and arguments" do
    clock = boot_with("  driven_by \"Clock\"\n#{MORNING}").registry.hecksagon("Lending").clocks.first

    expect(clock.to_h).to include(name: "Morning", trigger: "cron", expression: "30 6 * * *", zone: "America/Phoenix",
                                  command: "Loan.OpenLoan", with: { name: "firing_id", day: "fire_date" })
  end

  it "refuses at boot a hecksagon whose clocks it does not admit with driven_by \"Clock\"" do
    expect { boot_with(MORNING) }.to raise_error(Hecks::Runtime::WiringError, /clock "Morning" but is not driven_by "Clock"/)
  end

  it "refuses at boot a clock that dispatches a command the bluebook does not declare" do
    expect { boot_with("  driven_by \"Clock\"\n#{MORNING.sub("OpenLoan", "CloseLoan")}") }
      .to raise_error(Hecks::Runtime::WiringError, /names no command Lending declares/)
  end

  it "refuses a clock that names two triggers" do
    expect { boot_with("  driven_by \"Clock\"\n#{MORNING.sub("  dispatch", "  every \"1h\"\n  dispatch")}") }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /2 triggers/)
  end

  it "dispatches its command through the storehouse at the tick, as the clock, with the firing's date", :aggregate_failures do
    runtime = boot_with("  driven_by \"Clock\"\n#{MORNING}")
    allow(Hecks::Storehouse).to receive(:dispatch).and_call_original
    expect(runner(runtime, FakeTime.new(morning)).run(ticks: 1)).to eq(1)
    expect(Hecks::Storehouse).to have_received(:dispatch).with(hash_including(source: "clock", command: "loan.open_loan"))
    expect(runtime.registry.repository("Lending", runtime.bluebook("Lending").aggregate("Loan")).count).to eq(1)
  end

  it "skips a tick it wakes too late for, logs the skip and does not replay it", :aggregate_failures do
    runtime = boot_with("  driven_by \"Clock\"\n#{MORNING}")
    expect(runner(runtime, FakeTime.new(morning, 600)).run(ticks: 1)).to eq(0)
    expect(log.string).to include("skipped 2026-11-23T06:30:00-07:00", "not replayed")
  end

  it "lists each clock with when it next fires" do
    runtime = boot_with("  driven_by \"Clock\"\n#{MORNING}")

    expect(Hecks::Adapters::Driving::Clock.upcoming(runtime, morning)).to include("Morning", "next: 2026-11-23T06:30:00-07:00")
  end

  it "projects one Procfile line per clock" do
    expect(Hecks::Adapters::Driving::Clock::LaunchFiles.procfile("/journal", %w[MorningPrintout]))
      .to eq("morning_printout: hecks Clock.run! domain.value=/journal clock.value=MorningPrintout")
  end
end
