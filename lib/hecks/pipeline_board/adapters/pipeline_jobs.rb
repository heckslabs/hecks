# frozen_string_literal: true

require "json"
require "time"
require_relative "cache"

module Hecks
  module Adapters
    # The `Jobs` port's adapter: answers `Sessions` with the dispatched sessions of the last day,
    # from each job's own `state.json` and `timeline.jsonl` and from `claude agents --json`. It
    # reads the job's state and never the ledger, and writes nothing.
    class PipelineJobs
      WINDOW_SECONDS = 24 * 3600
      FRESH_SECONDS = 600

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `jobs_dir:` the directory of jobs, `agents:` a callable answering
      #   the parsed `claude agents --json`, `runs:` a callable answering session id =>
      #   `{work_item:}`,
      #   `now:` a callable answering the time
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @dir = settings[:jobs_dir] || File.join(Dir.home, ".claude", "jobs")
        @agents = settings[:agents] || -> { PipelineBoard::Probe.json("claude", "agents", "--json") }
        @runs = settings[:runs] || -> { {} }
        @now = settings[:now] || -> { Time.now }
        @cache = PipelineBoard::Cache.new(ttl: settings.fetch(:ttl, 15))
      end

      # @return [Hash{Symbol => String}] `text:` the sessions as JSON, busy first, then newest first
      def sessions = { text: JSON.generate(rows) }

      # @return [Array<Hash>] the sessions, each with `id`, `name`, `status`, `state`, `detail`,
      #   `started`, `ended` and the `work_item` it was dispatched for
      def rows
        agents = listed
        found = Dir.glob(File.join(@dir, "*", "state.json")).filter_map { |path| session(path, agents) }
        found.sort_by { |row| [row[:status] == "busy" ? 0 : 1, row[:started].to_s] }.reverse
      end

      private

      def listed
        @cache.fetch(:agents) { Array(@agents.call).to_h { |agent| [agent["id"].to_s, agent] } }
      rescue PipelineBoard::Unavailable
        {}
      end

      def session(path, agents)
        id = File.basename(File.dirname(path))
        age = @now.call - File.mtime(path)
        agent = agents[id]
        return if age > WINDOW_SECONDS && !agent

        build(id, JSON.parse(File.read(path)), agent, age, File.join(File.dirname(path), "timeline.jsonl"))
      rescue JSON::ParserError, SystemCallError
        nil
      end

      def build(id, state, agent, age, timeline)
        edges = edges_of(timeline)
        status = status_of(state, agent, age)
        { id: id, name: name_of(id, agent), status: status, state: state["state"].to_s,
          detail: state["detail"].to_s.slice(0, 140), started: stamp(agent, edges),
          ended: %w[busy blocked].include?(status) ? nil : edges.last, work_item: @runs.call.dig(id, :work_item).to_s }
      end

      def name_of(id, agent) = (agent && agent["name"]) || id

      # A session is `blocked` when its job says so and it is still alive: it waits on a person.
      def status_of(state, agent, age)
        fresh = age < FRESH_SECONDS
        return "blocked" if state["state"] == "blocked" && (agent || fresh)
        return "busy" if busy?(state, agent, fresh)

        %w[failed error].include?(state["state"]) ? "failed" : "done"
      end

      def busy?(state, agent, fresh) = (agent && agent["status"] == "busy") || (state["state"] == "working" && fresh)

      def stamp(agent, edges)
        agent ? Time.at(agent["startedAt"].to_i / 1000).utc.iso8601 : edges.first
      end

      def edges_of(timeline)
        lines = File.readlines(timeline)
        [lines.first, lines.last].map { |line| JSON.parse(line)["at"] }
      rescue SystemCallError, JSON::ParserError
        []
      end
    end
  end
end
