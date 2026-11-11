require "tmpdir"
require "hecks/hecks/adapters/ticking"

# Drives the Ticker chain against the Delegate domain in Memory, with a recorder where the
# `Ticking` port would start its detached process.
module TickerChain
  def started = (@started ||= [])

  def ticking
    @ticking ||= Hecks::Adapters::Ticking.new(
      registry: @hecks.registry, root: Dir.pwd,
      settings: { spawner: ->(*argv) { started << argv }, seconds: 20, minutes: 1, persisted: true,
                  dir: Dir.mktmpdir("ticker-logs") }
    )
  end

  def dispatch(verb, **args)
    Hecks::Runtime::Dispatcher.new(@hecks.registry).dispatch_flat("Hecks::#{verb}", **args)
  end

  def start(run)
    lookup = ->(port, _asked) { port.to_s == "Ticking" ? ticking : nil }
    Hecks::Runtime::AdapterLookup.standing_in(lookup) { dispatch("Ticker.Start", run: { value: run }) }
  end

  def tick(run, count)
    dispatch("Ticker.Tick", ticker: run, tick: { value: "#{run}-#{count}" }, beats: { value: count })
  end

  def names = @hecks.registry.event_log.map(&:name)
end
