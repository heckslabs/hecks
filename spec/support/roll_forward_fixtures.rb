require "hecks/hecks/adapters/rolling"

# Planned work rolls forward by itself, in priority order. The Work records are stand-ins
# read by the real {WorkItems}.
module RollForwardFixtures
  Entry = Struct.new(:work, :title, :status, :priority, :step, :area, :detail, keyword_init: true)
  Item = Hecks::Adapters::Dispatching::Plan::Item
  Word = Struct.new(:value)

  def entry(key, priority: nil, step: nil)
    Entry.new(work: key, title: key, status: "planned", priority: priority, step: step, area: [Word.new(key)], detail: "")
  end

  def registry_of(entries, world = {})
    repository = double(all: entries)
    bluebook = double(aggregates: [double(hecks_name: "Work")])
    double(bluebook: bluebook, repository: repository, world: double(for_verb: world))
  end

  def ordered(*specs)
    entries = specs.map { |key, rest| entry(key, **(rest || {})) }
    Hecks::Adapters::Dispatching::WorkItems.new(registry_of(entries)).planned.map(&:key)
  end

  def plan_of(areas)
    planned = areas.map { |key, area| Item.new(key: key, title: key, detail: "", area: area) }
    Hecks::Adapters::Dispatching::Plan.new(planned, [], cap: 5, load: 0.0, max_load: 9.0, frozen: [])
  end

  def start_roll
    registry = boot_hecks_in_memory(File.expand_path("../../lib/hecks/hecks", __dir__)).registry
    Hecks::Runtime::AdapterLookup.standing_in(->(_port, _asked) { rolling({}) }) do
      Hecks::Runtime::Dispatcher.new(registry).dispatch_flat("Hecks::Roll.Start", run: { value: "roll-1" })
    end
    registry.event_log.map(&:name)
  end

  def rolling(world)
    items = instance_double(Hecks::Adapters::Dispatching::WorkItems, planned: [], started: [], lessons: [], runs: {})
    settings = { load: -> { 0.5 }, cpus: 4, work_items: items, runner: ->(*) { raise "no launch" } }
    Hecks::Adapters::Rolling.new(registry: registry_of([], world), settings: settings)
  end
end
