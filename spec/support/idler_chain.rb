require "tmpdir"
require "hecks/hecks/adapters/idling"

# Drives the Idler chain against the Delegate domain in Memory, with a recorder where the `Idling`
# port would start its detached process. The one idler record is shared, so a spec boots its own.
module IdlerChain
  def started = (@started ||= [])

  def idling
    @idling ||= Hecks::Adapters::Idling.new(
      registry: @hecks.registry, root: Dir.pwd,
      settings: { spawner: ->(env, *argv) { started << [env, argv] }, minutes: 10, persisted: true,
                  dir: Dir.mktmpdir("idler-logs") }
    )
  end

  def dispatch(verb, **args)
    Hecks::Runtime::Dispatcher.new(@hecks.registry).dispatch_flat("Hecks::#{verb}", **args)
  end

  def answer_roll(key, held_back)
    lookup = ->(port, _asked) { port.to_s == "Idling" ? idling : nil }
    Hecks::Runtime::AdapterLookup.standing_in(lookup) do
      dispatch("Roll.Start", run: { value: key })
      dispatch("Roll.Record", roll: key, report: { value: "r-#{key}" }, held_back: { value: held_back })
    end
  end

  def tick(count)
    dispatch("Idler.Tick", idler: "idle", tick: { value: "idle-1-#{count}" }, beats: { value: count })
  end

  def names = @hecks.registry.event_log.map(&:name)
end
