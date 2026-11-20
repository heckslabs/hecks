require "hecks/hecks/adapters/dispatching"

# A fill with free places that starts nothing, for the stall specs: one rollable work item, five
# started under a cap of seven, and a load over the limit. The work items, the machine and the
# clock are stand-ins a spec changes between watches; no live store is read.
module FillStallWatches
  DISPATCHING = Hecks::Adapters::Dispatching

  def stall_now = (@stall_now ||= [Time.utc(2026, 11, 20, 10, 0, 0)])

  def stall_machine = (@stall_machine ||= { load: 22.8, cap: 7, planned: 1, started: 5 })

  def stall_item(key) = DISPATCHING::Plan::Item.new(key: key, title: key, detail: "", area: [key])

  def stall_items(kind) = Array.new(stall_machine[kind]) { |index| stall_item("#{kind}-#{index}") }

  def stall_work_items
    planned = stall_items(:planned)
    instance_double(DISPATCHING::WorkItems, planned: planned, rollable: planned, started: stall_items(:started), runs: {},
                                            lessons: [])
  end

  def stall_settings
    { load: -> { stall_machine[:load] }, cpus: 10, cap: stall_machine[:cap], work_items: stall_work_items,
      boots: Hecks::Adapters::BootBudget.new(entries: ->(_cutoff) { [] }, now: -> { stall_now.last }),
      now: -> { stall_now.last }, runner: ->(*) { raise "no launch" } }
  end

  def stall_rolling = stall_machine.fetch(:rolling, true)

  # The owner's switch, on unless a spec turns it off; the booted world's own is not read.
  def stall_switch
    allow(DISPATCHING::Settings).to(receive(:new).and_wrap_original do |original, *args, **options|
      original.call(*args, **options).tap { |made| allow(made).to receive(:roll_forward?) { stall_rolling } }
    end)
  end

  # The adapter over a fresh read of the stand-ins, so a spec may change them between watches.
  def stall_dispatching(registry)
    DISPATCHING::Pending.reset!
    stall_switch
    DISPATCHING.new(registry: registry, settings: stall_settings)
  end

  def minutes_before(minutes) = (stall_now.last - (minutes * 60)).utc.iso8601
end
