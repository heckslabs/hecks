require "spec_helper"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require "hecks/quality_control/cli/qa_event_pump"
require "hecks/quality_control/cli/qa_tick"

# The QA event pump: each attached domain's policies read the events past their cursors. The logs
# are read through the `Operation.Follow` query, which a fresh boot of a Memory domain cannot answer
# across processes, so these examples stub only that read and feed it entries the producer emitted.
RSpec.describe Hecks::QualityControlCli::QaEventPump do
  PUMP_PRODUCER = <<~RUBY.freeze
    Hecks.bluebook "Producer" do
      vision "Pings."

      aggregate "Ping" do
        description "A ping."

        attribute :name, PingName
        identified_by :name

        value_object "PingName" do
          attribute :value, String
          invariant("a ping is named") { !value.to_s.empty? }
        end

        command "Send" do
          attribute :name, PingName
          sets :name
          emits "Pinged"
        end
      end
    end
  RUBY

  PUMP_CONSUMER = <<~RUBY.freeze
    Hecks.bluebook "Consumer" do
      vision "Counts pings."

      aggregate "Tally" do
        description "A count of one name's pings."

        attribute :name, TallyName
        identified_by :name

        value_object "TallyName" do
          attribute :value, String
          invariant("a tally is named") { !value.to_s.empty? }
        end

        command "Count" do
          attribute :name, TallyName
          sets :name
          emits "Counted"
        end
      end

      policy "CountOnPinged" do
        on      "Ping.Pinged"
        trigger Tally::Count, with: { name: :name }
      end
    end
  RUBY

  PUMP_PRODUCER_HECKSAGON = %(Hecks.hecksagon "Producer" do\n  persisted_by "Memory"\nend\n).freeze
  PUMP_CONSUMER_HECKSAGON = %(Hecks.hecksagon "Consumer" do\n  persisted_by "Memory"\n  subscribe "Producer.Pinged"\nend\n).freeze
  PUMP_LEDGER = File.expand_path("../lib/hecks/quality_control", __dir__)

  around do |example|
    @dir = Dir.mktmpdir("event_pump")
    write_domain("producer", PUMP_PRODUCER, PUMP_PRODUCER_HECKSAGON)
    write_domain("consumer", PUMP_CONSUMER, PUMP_CONSUMER_HECKSAGON)
    example.run
  ensure
    FileUtils.rm_rf(@dir)
  end

  let(:producer) { Hecks.boot(producer_dir) }
  let(:logs) { Hash.new { |hash, dir| hash[dir] = [] } }
  let(:attached) do
    Hecks::QualityControlCli::QaEventPump::Attached.new(
      root: @dir, dirs: { "QualityControl" => PUMP_LEDGER, "Producer" => producer_dir, "Consumer" => consumer_dir }
    )
  end
  let(:pump) { described_class.new(root: @dir, attached: attached) }

  before do
    allow(Hecks::QualityControlCli::QaEventPump::Reader).to receive(:after) do |dir, position|
      { cursor: logs[dir].size, events: logs[dir].drop(position) }
    end
  end

  def producer_dir = File.join(@dir, "producer")

  def consumer_dir = File.join(@dir, "consumer")

  def write_domain(name, bluebook, hecksagon)
    FileUtils.mkdir_p(File.join(@dir, name))
    File.write(File.join(@dir, name, "#{name}.bluebook"), bluebook)
    File.write(File.join(@dir, name, "#{name}.hecksagon"), hecksagon)
  end

  # Sends one ping through the producer and records what its log now holds for the pump to read.
  def ping(name)
    producer.dispatch_flat("Producer::Ping.Send", name: name)
    entry_for(producer.events.last)
  end

  def entry_for(event)
    { "name" => event.name, "aggregate" => event.aggregate, "id" => event.id,
      "payload" => JSON.generate(event.payload), "occurred_at" => event.occurred_at }
  end

  def publish(*entries) = logs[producer_dir].concat(entries)

  def counted_reactions
    attached.runtime("Consumer").registry.reaction_log.count { |record| record[:policy] == "CountOnPinged" && record[:delivered] }
  end

  def pump_output
    original = $stdout
    $stdout = StringIO.new
    pump.run
    $stdout.string
  ensure
    $stdout = original
  end

  it "picks up a new event and runs its policy once", :aggregate_failures do
    publish(ping("a"))

    expect(pump_output).to include("reacted: Consumer <- Producer Pinged: CountOnPinged")
    expect(counted_reactions).to eq(1)
  end

  it "does nothing on a second run with no new events", :aggregate_failures do
    publish(ping("a"))
    pump_output

    expect(pump_output).not_to include("reacted")
    expect(counted_reactions).to eq(1)
  end

  it "records a refused reaction, names it, and does not block the next event", :aggregate_failures do
    count_already("a")
    publish(ping("a"), ping("b"))

    output = pump_output

    expect(output).to include("refused: Consumer <- Producer Pinged: CountOnPinged")
    expect(output).to include("reacted: Consumer <- Producer Pinged: CountOnPinged")
  end

  it "advances the cursor past a refused event" do
    count_already("a")
    publish(ping("a"), ping("b"))
    pump_output

    expect(position_of("Producer", "Consumer")).to eq(2)
  end

  it "keeps one cursor per consumer on each log", :aggregate_failures do
    publish(ping("a"))
    pump_output
    open_auditor_cursor

    expect(position_of("Producer", "Consumer")).to eq(1)
    expect(position_of("Producer", "Auditor")).to eq(0)
  end

  it "does not react to an event the ledger already holds a reaction for" do
    entry = ping("a")
    publish(entry)
    recorded_reactions.record("Consumer", entry["id"], "CountOnPinged")

    pump_output

    expect(counted_reactions).to eq(0)
  end

  it "does not rerun a command after a stop between the command and the cursor write" do
    stop_before_the_first_cursor_write
    publish(ping("a"))

    2.times { pump_output }

    expect(counted_reactions).to eq(1)
  end

  it "records a refused reaction, and the reaction after it still runs" do
    count_already("a")
    refused = ping("a")
    publish(refused, ping("b"))

    pump_output

    expect(recorded?(refused)).to be(true)
  end

  it "runs each reaction once across two passes in a row" do
    publish(ping("a"), ping("b"))

    2.times { pump_output }

    expect(counted_reactions).to eq(2)
  end

  it "skips an event a consumer already reacted to in this process, keyed by its id", :aggregate_failures do
    entry = ping("a")
    publish(entry)
    react_in_process(entry)

    expect(pump_output).not_to include("reacted")
    expect(counted_reactions).to eq(1)
  end

  it "reads an event another boot wrote, on a pump booted fresh", :aggregate_failures do
    publish(ping("a"))
    fresh_attached = attached_fresh

    expect(capture_output { described_class.new(root: @dir, attached: fresh_attached).run })
      .to include("reacted: Consumer <- Producer Pinged: CountOnPinged")
    expect(counted_reactions_on(fresh_attached)).to eq(1)
  end

  def react_in_process(entry)
    consumer = attached.runtime("Consumer")
    event = Hecks::QualityControlCli::QaEventPump::Reader.event(entry)
    policy, home = consumer.outbox.policies_for(event, "Producer").first
    consumer.outbox.react_policy(event, policy: policy, home: home, domain: "Producer", event_uid: nil)
  end

  def attached_fresh
    Hecks::QualityControlCli::QaEventPump::Attached.new(
      root: @dir, dirs: { "QualityControl" => PUMP_LEDGER, "Producer" => producer_dir, "Consumer" => consumer_dir }
    )
  end

  def counted_reactions_on(boot)
    boot.runtime("Consumer").registry.reaction_log.count { |record| record[:policy] == "CountOnPinged" && record[:delivered] }
  end

  def capture_output
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  def ledger = attached.runtime("QualityControl")

  # Counts a name on the consumer first, so the pumped `Count` for that name is refused.
  def count_already(name) = attached.runtime("Consumer").dispatch_flat("Consumer::Tally.Count", name: name)

  def recorded_reactions = Hecks::QualityControlCli::QaEventPump::Reactions.new(ledger)

  def recorded?(entry) = recorded_reactions.recorded?("Consumer", entry["id"], "CountOnPinged")

  # Lets the cursor write fail once, after the policy's command has answered, as a stop would.
  def stop_before_the_first_cursor_write
    cursors = Hecks::QualityControlCli::QaEventPump::Cursors.new(ledger)
    allow(Hecks::QualityControlCli::QaEventPump::Cursors).to receive(:new).and_return(cursors)
    stopped = false
    allow(cursors).to receive(:advance).and_wrap_original do |original, *args|
      next original.call(*args) if stopped

      stopped = true
      raise "stopped before the cursor was written"
    end
  end

  def open_auditor_cursor
    Hecks::QualityControlCli::QaEventPump::Cursors.new(attached.runtime("QualityControl")).position("Producer", "Auditor")
  end

  def position_of(log, consumer)
    row = attached.runtime("QualityControl").query("QualityControl::EventCursor.All")
                  .find { |found| found[:key][:value] == "#{log}/#{consumer}" }
    row[:position][:value]
  end
end
