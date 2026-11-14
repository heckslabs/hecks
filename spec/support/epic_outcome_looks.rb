require "json"
require "time"
require "tmpdir"
require "hecks/tickets/bluebook/adapters/outcome_readings"

# An epic whose members close against a throwaway event tap, in a Hecks domain booted in Memory.
# The `OutcomeReadings` port reads the spec's own tap; every other port is the booted one.
module EpicOutcomeLooks
  def cli(*argv)
    Hecks::Runtime::AdapterLookup.standing_in(method(:adapter_for)) { run_cli(argv) }
  end

  # The spec's tap reader for `OutcomeReadings`, and the booted adapter for every other port.
  def adapter_for(port, asked)
    return Hecks::Adapters::OutcomeReadings.new(registry: hecks.registry, tap: tap) if port.to_s == "OutcomeReadings"

    lookup = Hecks::Runtime::AdapterLookup
    lookup.standing_in(nil) { lookup.call(hecks.registry, port, asked: asked) }
  end

  def run_cli(argv)
    Hecks::Adapters::Driving::CliRunner.call(runtime: hecks, program: "hecks", argv: ["tickets", *argv]).first
  end

  def epic(measure = "load-stays-under-its-mark")
    cli("epic.open!", "epic.value=e1", "title.value=Epic e1", "outcome.value=It is carried out")
    cli("epic.measure_by!", "to=e1", "measure.value=#{measure}") if measure
  end

  def member(key)
    cli("work.plan!", "work.value=#{key}", "title.value=Step #{key}")
    cli("work.assign!", "to=#{key}", "epic=e1")
  end

  def close_members(*keys)
    keys.each { |key| member(key) }
    finish(*keys)
  end

  def finish(*keys) = keys.each { |key| cli("work.finish!", "to=#{key}") }

  # An epic whose one member closed while the load had risen at each of the minutes given.
  def missed_epic(*minutes_ago)
    write_tap(*load_rose(*minutes_ago))
    epic
    close_members("m1")
  end

  def evidence_item = work("e1-outcome-1")

  # @param rows [Array<Array(String, String, String, Integer)>] aggregate, event, id, minutes ago
  def write_tap(*rows)
    lines = rows.each_with_index.map do |(aggregate, event, id, ago), seq|
      { kind: "event", at: (Time.now.utc - (ago * 60)).iso8601, aggregate: aggregate, id: id, event: event, seq: seq + 1 }
    end
    File.write(tap, lines.map { |entry| "#{JSON.generate(entry)}\n" }.join)
  end

  def load_rose(*minutes_ago) = minutes_ago.map { |ago| ["Hecks::Machine", "LoadRoseAbove", "beat-#{ago}", ago] }

  def stored(name)
    aggregate = hecks.registry.bluebook("Tickets").aggregates.find { |declared| declared.hecks_name == name }
    hecks.registry.repository("Tickets", aggregate).all
  end

  def plain(value) = value.respond_to?(:value) ? value.value : value

  def the_epic = stored("Epic").first

  def status = plain(the_epic.status)

  def evidence = plain(the_epic.evidence).to_s

  def work(key) = stored("Work").find { |item| plain(item.work) == key }

  def work_keys = stored("Work").map { |item| plain(item.work) }

  def event_count(name) = hecks.registry.event_log.map(&:name).count(name)
end

RSpec.shared_context "with an epic outcome tap" do
  include EpicOutcomeLooks

  let(:hecks) { boot_hecks_in_memory }
  let(:dir) { Dir.mktmpdir("hecks-epic-outcome") }
  let(:tap) { File.join(dir, "events.jsonl") }

  before { write_tap }
  after { FileUtils.remove_entry(dir) }
end
