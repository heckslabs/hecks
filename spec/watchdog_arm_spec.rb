require "spec_helper"
require "securerandom"

# `Watchdog.Arm` and `Watchdog.Disarm` record a request, and the `Guarding` port answers or refuses
# it: the domain claims no guard before the outside has put it in place. The port is a stand-in,
# so no launch agent is written. The roster is declared by the bluebook, never by a file.
RSpec.describe "asking for the watchdog that restarts the pinned sessions" do
  before(:all) { @hecks = boot_hecks_in_memory }

  before { @hecks.registry.event_log.clear }

  def port(answer)
    Object.new.tap do |stand_in|
      stand_in.define_singleton_method(:guard) { |**| answer.call }
      stand_in.define_singleton_method(:release) { |**| answer.call }
    end
  end

  def ask(command, answer)
    Hecks::Runtime::AdapterLookup.standing_in(->(_port, _asked) { port(answer) }) do
      Hecks::Runtime::Dispatcher.new(@hecks.registry)
                                .dispatch_flat("Hecks::Watchdog.#{command}", run: SecureRandom.uuid, confirm: true)
    end
  end

  def names = @hecks.registry.event_log.map(&:name)

  let(:done) { -> { { report: { value: "guarding" } } } }
  let(:refused) { -> { raise Hecks::Adapters::ConsoleCapture::Failure, "launchctl refused" } }

  def rows(name)
    watchdog = @hecks.registry.bluebook("Hecks").aggregates.find { |aggregate| aggregate.hecks_name == "Watchdog" }
    watchdog.value_objects.find { |object| object.hecks_name == name }.members
  end

  it "records the request and the port's answer", :aggregate_failures do
    ask("Arm", done)
    expect(names).to include("ArmRequested", "GuardAnswered", "WatchdogGuarded")
    expect(names).not_to include("GuardRefused")
  end

  it "records the port's refusal, and no guard" do
    ask("Arm", refused)
    expect(names).to include("ArmRequested", "GuardRefused", "WatchdogRefused")
  end

  it "asks for the release the same way" do
    ask("Disarm", done)
    expect(names).to include("DisarmRequested", "ReleaseAnswered", "WatchdogReleased")
  end

  it "declares the lead, miette and the scrum master as pinned sessions with their loops" do
    pinned = rows("PinnedSession").map { |row| row[:name] }
    expect(pinned).to include("ORCHESTRATOR", "miette", "SCRUM MASTER")
  end

  it "declares the lead's loops: its watch pass, its quick check and its inbox watch", :aggregate_failures do
    loops = rows("WatchedLoop").select { |row| row[:session] == "ORCHESTRATOR" }
    expect(loops.map { |row| row[:kind] }).to include("cron", "monitor")
    expect(loops.map { |row| row[:schedule] }).to include("7,37 * * * *")
  end
end
