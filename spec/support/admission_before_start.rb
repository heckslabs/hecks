# frozen_string_literal: true

require "hecks/hecks/adapters/dispatching"

# A confirmed fill of the probe of 2026-11-20 06:29: the plan's beat admits, and the beat read just
# before the start says what a spec's `ruling` says. The launcher's commands are answered by a
# stand-in runner that records each command's name; no session starts.
module AdmissionBeforeStart
  # @return [Array<String>] each command the fill ran, by name
  def calls = @calls ||= []

  # @param key [String] the work item's key
  # @param priority [String] its priority; `expedite` passes the short band in the plan
  # @return [Hecks::Adapters::Dispatching::Plan::Item] a planned coder's work item
  def item_of(key, priority = "next")
    Hecks::Adapters::Dispatching::Plan::Item.new(key: key, title: key, detail: "", area: [key], priority: priority)
  end

  # @param ruling [String, nil] the refusal the beat before the start gives, nil when it admits
  # @param planned [Array<Hecks::Adapters::Dispatching::Plan::Item>] the planned work items
  # @return [String] the fill's report
  def fill(ruling, planned = [item_of("sim-properties-independent")])
    items = instance_double(Hecks::Adapters::Dispatching::WorkItems, planned: planned, started: [], runs: {}, lessons: [])
    settings = { load: -> { 1.0 }, cpus: 4, work_items: items, runner: runner, admitting: admission(ruling) }
    Hecks::Adapters::Dispatching.new(settings: settings).choose(repo: "/repo", confirm: { value: true }).dig(:report, :value)
  end

  private

  def admission(ruling) = double(reason: nil, clause: "admission by headroom 6879 MB", admit!: ruling)

  def runner
    lambda do |argv|
      calls << argv.find { |word| word.end_with?("!") }
      Hecks::Adapters::Shell::Result.new("", "", instance_double(Process::Status, success?: true))
    end
  end
end
