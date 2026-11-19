require "json"
require "hecks/hecks/adapters/rolling"

# A queue in scratch state for the rolls a work item's end starts. The `Rolling` port is answered
# by the real adapter over a stand-in board of work items; its launcher's `Work.start!` and
# `Work.yield!` move the board and dispatch the same command on the booted registry, as the
# in-process launcher does, so the registry's Work items emit the events the policies hear.
module RefillQueue
  Item = Hecks::Adapters::Dispatching::Plan::Item

  # Every other port the reactions reach, answered with no facts: the checks a start asks for pass.
  class Answering
    def respond_to_missing?(*) = true

    def method_missing(*) = {}
  end

  # The planned and started work items a roll reads, and every launcher call it made.
  class Board
    attr_reader :calls

    # @param keys [Array<String>] the planned work items, all claiming the same area
    def initialize(keys)
      @planned = keys.map { |key| Item.new(key: key, title: key, detail: "", area: ["lib/shared"]) }
      @started = []
      @calls = []
    end

    def planned = @planned.dup

    def started = @started.dup

    def runs = @started.to_h { |item| [item.key, { status: "started" }] }

    def rollable = planned

    def lessons = []

    def claimed_at(*) = ""

    def landed_commits(*) = []

    def landing_in_flight?(*) = false

    def start(key) = @started << @planned.delete(find(@planned, key))

    def finish(key) = @started.delete(find(@started, key))

    # Back to the plan with the yield's kind and retry time, as `Work.yield!` records them.
    def yield_back(key, kind, retry_at)
      item = @started.delete(find(@started, key))
      @planned << Item.new(**item.to_h, yield_kind: kind, retry_at: retry_at, yield_count: 1)
    end

    def launches(key) = @calls.count { |argv| argv.include?("Work.start!") && argv.include?("to=#{key}") }

    def fills = @calls.count { |argv| argv.include?("LinkedTree.pull_main!") || argv.include?("LinkedTree.PullMain") }

    private

    def find(items, key) = items.find { |item| item.key == key }
  end

  def board = @board ||= Board.new(%w[alpha beta])

  def hecks = @hecks ||= boot_hecks_in_memory

  def failing = @failing ||= []

  # Runs the block with the roll answered over the board.
  def rolling(&)
    Hecks::Adapters::Dispatching::LastRoll.reset!
    Hecks::Adapters::Dispatching::Pending.reset!
    Hecks::Runtime::AdapterLookup.standing_in(->(port, _asked) { port == "Rolling" ? roll_adapter : Answering.new }, &)
  end

  def plan_work(key)
    hecks.dispatch_flat("Tickets::Work.Plan", work: { value: key }, title: { value: key }, detail: { value: "d" },
                                              area: [{ value: "lib/shared" }])
  end

  # The landing's close: the board drops the holder, then the registry records it done.
  def land(key)
    board.finish(key)
    hecks.dispatch_flat("Tickets::Work.Close", work: { value: key }, landing: { value: "abc123" })
  end

  # A holder's own yield: the board returns it to the plan, then the registry records it.
  def yield_holder(key)
    board.yield_back(key, "", "")
    hecks.dispatch_flat("Tickets::Work.Yield", work: { value: key }, reason: { value: "rethink" })
  end

  def reaction(policy) = hecks.reactions.find { |row| row[:policy] == policy }

  private

  def roll_adapter
    @roll_adapter ||= Hecks::Adapters::Rolling.new(registry: world_registry, settings: roll_settings)
  end

  def roll_settings
    { load: -> { 0.5 }, cpus: 4, cap: 4, work_items: board, runner: method(:run),
      sessions: double(quiet?: false) }
  end

  def world_registry
    kinds = double(hecks_name: "YieldKind", members: [{ kind: "load", first: true }, { kind: "transient", first: false }])
    bluebook = double(aggregates: [double(hecks_name: "Work", value_objects: [kinds])])
    double(bluebook: bluebook, repository: double(all: []), world: double(for_verb: {}))
  end

  def run(argv)
    board.calls << argv
    mirror(argv)
    out = argv.include?("Brief.compose!") ? JSON.generate("state" => { "outcome" => "x" }) : ""
    ok = !(argv.include?("Brief.compose!") && failing.any? { |key| argv.include?("work.value=#{key}") })
    Hecks::Adapters::Shell::Result.new(out, ok ? "" : "no brief", instance_double(Process::Status, success?: ok))
  end

  def mirror(argv)
    key = argv.find { |word| word.start_with?("to=") }&.delete_prefix("to=")
    if argv.include?("Work.start!") then mirror_start(key)
    elsif argv.include?("Work.yield!") then mirror_yield(key, argv)
    end
  end

  def mirror_start(key)
    board.start(key)
    hecks.dispatch_flat("Tickets::Work.Start", work: { value: key }, claimed_by: { value: "dispatch" },
                                               claimed_at: { value: "2026-11-19T00:00:00Z" })
  end

  def mirror_yield(key, argv)
    value = ->(name) { argv.find { |word| word.start_with?("#{name}.value=") }.to_s.delete_prefix("#{name}.value=") }
    board.yield_back(key, value.call("yield_kind"), value.call("retry_at"))
    hecks.dispatch_flat("Tickets::Work.Yield", work: { value: key }, reason: { value: value.call("reason") })
  end
end
