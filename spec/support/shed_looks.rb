require "hecks/hecks/adapters/dispatching"
require_relative "machine_beats"

# Beats of a clock over a fake load series, with a fake listing of started work items behind the
# Dispatching port and a stand-in for the sessions behind the Agents port. The runs, the Shed
# rows and every policy are the booted Hecks domain's own.
module ShedLooks
  include MachineBeats

  Item = Hecks::Adapters::Dispatching::Plan::Item

  # The started work items a spec names, over the registry's own runs and rows.
  class Listing < Hecks::Adapters::Dispatching::WorkItems
    attr_writer :started, :landing_work

    def started = @started || []

    def landing_work = @landing_work || []
  end

  # The sessions: every run starts one, each is listed busy, and an answer is delivered in place.
  class Sessions
    attr_reader :delivered, :stopped

    def initialize
      @delivered = []
      @stopped = []
      @starts = 0
    end

    # The agent is listed, and no other run holds the work: the facts the real adapter answers.
    def locate(**) = { listed: true, holder: "", holder_status: "", holder_agent: "", requester_agent: "" }

    def start(**) = { session: "s-#{@starts += 1}", started_at: format("2026-11-14T10:%02d:00Z", @starts) }

    def present(**) = { listed: true, status: "busy", state: "working", note: "" }

    def deliver(**held) = (@delivered << held) && { queued_at: "2026-11-14T11:00:00Z", session: "s" }

    def stop_session(**held) = @stopped << held

    def respond_to_missing?(*) = true

    def method_missing(name, **) = raise(Hecks::Adapters::ConsoleCapture::Failure, "#{name} is not asked in this spec")
  end

  def registry = (@registry ||= boot_hecks_in_memory(File.expand_path("../../lib/hecks/hecks", __dir__)).registry)

  def sessions = (@sessions ||= Sessions.new)

  def listing = (@listing ||= Listing.new(registry))

  def dispatcher = Hecks::Runtime::Dispatcher.new(registry)

  # Starts a run for each work item, oldest first, and lists the items as started.
  #
  # @param priorities [Hash{String => String, nil}] each work item's key and priority
  def running(priorities)
    standing { priorities.each_key { |key| start_run(key) } }
    listing.started = priorities.map { |key, priority| item(key, priority) }
  end

  def item(key, priority) = Item.new(key: key, title: key, detail: "", area: [], priority: priority.to_s)

  def start_run(key)
    dispatcher.dispatch_flat("Hecks::AgentRun.Dispatch", run: { value: key }, repo: { value: Dir.pwd }, brief: { value: "work" })
  end

  def in_review(key) = standing { dispatcher.dispatch_flat("Hecks::AgentRun.Await", agent_run: key) }

  # Beats once for each load of the series, two minutes apart.
  def loads(*series)
    Sampling.last = nil
    readings = series.map { |load| gauge(60.0).merge(load: load) }
    standing(readings) { series.each_index { |index| beat(registry, "#{series.join("-")}-#{index}") } }
  end

  def standing(readings = [], &)
    seconds = 0
    sampling = Sampling.new(registry: registry, settings: { readings: -> { readings.shift }, clock: -> { seconds += 120 } })
    Hecks::Runtime::AdapterLookup.standing_in(->(port, _asked) { port_for(port.to_s, sampling) }, &)
  end

  def port_for(port, sampling)
    case port
    when "Sampling" then sampling
    when "Dispatching" then Hecks::Adapters::Dispatching.new(registry: registry, settings: { work_items: listing })
    else sessions
    end
  end

  def asked = sessions.delivered.map { |held| plain(held[:run]) }

  def asks = sessions.delivered.map { |held| plain(held[:answer]) }

  def events = registry.event_log.map(&:name)

  def spared = registry.event_log.select { |event| event.name == "ShedSpared" }.map { |event| reason_of(event.payload) }

  def reason_of(payload) = plain(payload.to_h.transform_keys(&:to_sym)[:refusal])

  def plain(value)
    return value.value if value.respond_to?(:value)

    value.is_a?(Hash) ? value[:value] : value
  end
end
