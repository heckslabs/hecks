require "json"
require "time"
require "hecks/hecks/adapters/stall_watching"
require_relative "roll_forward_fixtures"

# Looks of the StallWatch against a throwaway tap, in a Hecks domain booted in Memory. The group
# that includes it names `registry` and `tap`; every port but `Watching` is a rolling stand-in.
module StallWatchLooks
  include RollForwardFixtures

  # A review asked 30 minutes ago and never answered, one asked 5 minutes ago, and one answered.
  def write_tap
    lines = [line(1, "PlanReviewRequested", "late", 30), line(2, "PlanReviewRequested", "young", 5),
             line(3, "PlanReviewRequested", "answered", 40), line(4, "PlanReviewed", "answered", 35)]
    File.write(tap, lines.map { |entry| JSON.generate(entry) }.join("\n") << "\n")
  end

  def line(seq, event, id, minutes_ago)
    { kind: "event", at: (Time.now.utc - (minutes_ago * 60)).iso8601, aggregate: "Agents::PlanReview", id: id,
      event: event, seq: seq }
  end

  # Runs blocked 20 and 5 minutes ago, and one blocked then answered.
  def write_blocked_tap
    rows = [["SessionBlocked", "stuck", 20], ["SessionBlocked", "fresh", 5], ["SessionBlocked", "replied", 30],
            ["AgentRunAnswered", "replied", 25]]
    lines = rows.each_with_index.map { |(event, id, ago), seq| line(seq + 1, event, id, ago).merge(aggregate: "Hecks::AgentRun") }
    File.write(tap, lines.map { |entry| JSON.generate(entry) }.join("\n") << "\n")
  end

  def watching
    aggregate = registry.bluebook("Hecks").aggregate("StallWatch")
    Hecks::Adapters::StallWatching.new(registry: registry, aggregate: aggregate, tap: tap)
  end

  # Runs the block with `Watching` reading the spec's own tap and every other port stood in.
  def with_tap(&)
    rolled = rolling({})
    Hecks::Runtime::AdapterLookup.standing_in(->(port, _asked) { port.to_s == "Watching" ? watching : rolled }, &)
  end

  def dispatch(verb, **args) = Hecks::Runtime::Dispatcher.new(registry).dispatch_flat(verb, **args)

  def detect(run) = with_tap { dispatch("Hecks::StallWatch.Detect", run: { value: run }) }

  def keys(domain, name, field)
    aggregate = registry.bluebook(domain).aggregate(name)
    registry.repository(domain, aggregate).all.map { |record| Hecks::Adapters::StartedWork.value(record, field).to_s }
  end

  def plan(work, priority = nil)
    dispatch("Tickets::Work.Plan", work: { value: work }, title: { value: work })
    dispatch("Tickets::Work.Prioritize", work: { value: work }, priority: { value: priority }) if priority
  end
end

RSpec.shared_context "with a stall watch tap" do
  include StallWatchLooks

  let(:dir) { Dir.mktmpdir("hecks-stall-watch") }
  let(:tap) { File.join(dir, "events.jsonl") }
  let(:registry) { boot_hecks_in_memory.registry }

  after { FileUtils.remove_entry(dir) }
end
