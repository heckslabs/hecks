require "spec_helper"
require "securerandom"

# `Integration.Schedule` and `Integration.Unschedule` record a request, and the `Integrating` port
# answers or refuses it: the domain claims no outcome before the outside has done it. The port is a
# stand-in here, so nothing is written under the launch agents directory.
RSpec.describe "asking for the launchd job that beats the clock" do
  before(:all) { @hecks = boot_hecks_in_memory }

  before { @hecks.registry.event_log.clear }

  def port(answer)
    Object.new.tap do |stand_in|
      stand_in.define_singleton_method(:arrange) { |**| answer.call }
      stand_in.define_singleton_method(:withdraw) { |**| answer.call }
    end
  end

  def ask(command, answer)
    Hecks::Runtime::AdapterLookup.standing_in(->(_port, _asked) { port(answer) }) do
      Hecks::Runtime::Dispatcher.new(@hecks.registry)
                                .dispatch_flat("Hecks::Integration.#{command}", run: SecureRandom.uuid, confirm: true)
    end
  end

  def names = @hecks.registry.event_log.map(&:name)

  let(:done) { -> { { report: { value: "installed" } } } }
  let(:refused) { -> { raise Hecks::Adapters::ConsoleCapture::Failure, "launchctl refused" } }

  it "records the request and the port's answer", :aggregate_failures do
    ask("Schedule", done)
    expect(names).to include("ScheduleRequested", "ArrangeAnswered")
    expect(names).not_to include("ArrangeRefused")
  end

  it "records the port's refusal, and no answer" do
    ask("Schedule", refused)
    expect(names).to include("ScheduleRequested", "ArrangeRefused")
  end

  it "asks for the removal the same way" do
    ask("Unschedule", done)
    expect(names).to include("UnscheduleRequested", "WithdrawAnswered")
  end
end
