# frozen_string_literal: true

require "json"

# A recorded-shape `claude agents --json --all` listing
# (spec/fixtures/claude_agents/three_coders.json) and the AgentRun ledger's runs beside it, keyed
# as {Hecks::Adapters::Metering::LiveReads#runs} keys them: by the session's short listed `id`.
# Three coders run (one blocked), two helpers run, and finished sessions linger: a done coder and
# a failed answerer whose processes still run, and stopped sessions with no process.
module RecordedAgentsListing
  # The fixture the listing is read from.
  PATH = File.expand_path("../fixtures/claude_agents/three_coders.json", __dir__)

  module_function

  # @return [Array<Hash>] the listed sessions
  def listing = JSON.parse(File.read(PATH))

  # @return [String] a `ps` table in which every listed session with a pid still runs
  def processes = listing.filter_map { |entry| "#{entry["pid"]} 1 1024 0.0 claude" if entry["pid"] }.join("\n")

  # @return [Hash{String => Hash}] each run by its session's short id
  def runs
    { "c0de0001" => run("item-a", works_as: "coder"), "c0de0002" => run("item-b", works_as: "coder"),
      "c0de0003" => run("item-c", works_as: "coder"), "4e1b0001" => run("item-a-review", agent: "reviewer"),
      "d0ee0001" => run("item-d", works_as: "coder"),
      "d0ee0002" => run("answer-item-c", agent: "orchestrator", works_as: "answerer") }
  end

  # @return [Hash] one run, shaped as {Hecks::Adapters::Metering::LiveReads#runs} shapes it
  def run(name, agent: "", works_as: "")
    { run: name, agent: agent, works_as: works_as, work: name, status: "started" }
  end

  # @return [Hecks::Adapters::Metering] the meter over the recorded listing
  def metering
    Hecks::Adapters::Metering.new(settings: { listing: -> { listing }, processes: -> { processes },
                                              runs: -> { runs }, machine: -> { {} }, activity: ->(_) {},
                                              copies: -> { [] } })
  end
end
