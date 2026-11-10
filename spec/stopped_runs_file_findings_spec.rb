require "spec_helper"

# Emits a Hecks event into a booted Tickets runtime and reads the findings it filed.
module StoppedRunsHelpers
  TICKETS_DIR = File.expand_path("../lib/hecks/tickets/bluebook", __dir__)

  # The events that stop a run for a person, each with the stage it files and its reason field.
  STOPS = {
    %w[Integration MainVerificationFailed] => ["verifying", :refusal],
    %w[Integration MainPushRefused]        => ["boarding", :refusal],
    %w[Integration PullRequestClosed]      => ["ci_running", :report],
    %w[Shipment ShipmentStopped]           => ["boarding", :refusal]
  }.freeze

  # Events any run of a command emits, inside a shipment or not: none of them files a finding.
  ORDINARY = %w[StyleRun.StyleFaulted StyleRun.StyleRefused SendTrain.PushFaulted SendTrain.TrainRefused].freeze

  def payload(aggregate, reason_field, reason)
    key   = aggregate == "Integration" ? :landed : :run
    facts = { key => { value: "abc123" }, reason_field => { value: reason } }
    aggregate == "Shipment" ? facts.merge(stage: { value: "boarding" }) : facts
  end

  def emit(aggregate, name, reason_field, reason = "it stopped")
    event = Hecks::Runtime::Event.new(name: name, aggregate: aggregate, id: "event-#{reason}",
                                      payload: payload(aggregate, reason_field, reason))
    Hecks::Runtime::PolicyInterpreter.new(runtime.registry, dispatcher: runtime).react(event, "Hecks")
  end

  def stopped(*names)
    runtime.query("Tickets::Finding.Stopped").map do |record|
      names.map { |name| record[name].respond_to?(:value) ? record[name].value : record[name] }
    end
  end
end

# An integration run that parks for a person, or a shipment that parks for one, files one Finding
# in Tickets with the stage and the reason, keyed by the run. A style run or a boarding that faults
# outside a shipment files nothing: its caller reads the refusal. The Tickets bluebook boots alone
# in Memory and hears each event as the Hecks domain emits it.
RSpec.describe "stopped runs file findings" do
  include StoppedRunsHelpers

  let(:runtime) { Hecks.boot(StoppedRunsHelpers::TICKETS_DIR) }

  StoppedRunsHelpers::STOPS.each do |(aggregate, name), (stage, reason_field)|
    it "files one finding for #{aggregate}.#{name} with its stage and reason" do
      emit(aggregate, name, reason_field)
      expect(stopped(:finding, :stage, :body)).to eq([["abc123", stage, "it stopped"]])
    end

    it "files no second finding when #{aggregate}.#{name} stops the same run again" do
      emit(aggregate, name, reason_field, "first")
      emit(aggregate, name, reason_field, "second")
      expect(stopped(:body)).to eq([["first"]])
    end
  end

  StoppedRunsHelpers::ORDINARY.each do |event|
    it "files nothing for #{event}, which any run of that command emits" do
      emit(*event.split("."), :refusal)
      expect(stopped(:finding)).to be_empty
    end
  end

  it "names the landed commit of a parked integration run as a plain string" do
    emit("Integration", "MainVerificationFailed", :refusal)
    expect(stopped(:commit)).to eq([["abc123"]])
  end
end
