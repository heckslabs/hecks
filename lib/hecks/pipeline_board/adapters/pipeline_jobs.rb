# frozen_string_literal: true

require "json"
require "time"
require_relative "cache"
require_relative "rules"
require_relative "rows"
require_relative "session_context"

module Hecks
  module Adapters
    # The `Jobs` port's adapter: answers `Sessions` with the dispatched sessions of the last day,
    # from each job's own `state.json` and `timeline.jsonl` and from the AgentRun ledger (the
    # `runs:` callable), never from a `claude agents` call. A run's `condition` is as fresh as the
    # last session sweep. A session with a started or finished run shows whatever its age; one
    # with no run shows only inside `session_window_hours`. It writes nothing.
    class PipelineJobs
      # The kinds a session may tag its question with, in brackets at its start.
      KIND_PREFIX = /\A\s*\[(confirm|choose|retry|owner)\]/i

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `jobs_dir:` the directory of jobs, `runs:` a callable answering the
      #   AgentRun ledger as session id => `{work_item:, condition:, started_at:, ...}` for the
      #   runs not yet tidied, `now:` a callable answering the time
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @dir = settings[:jobs_dir] || File.join(Dir.home, ".claude", "jobs")
        @runs = settings[:runs] || -> { {} }
        @now = settings[:now] || -> { Time.now }
      end

      # @return [Array<Hash>] the sessions as `SessionLine` rows, busy first, then newest first
      def sessions = PipelineBoard::Rows.of("SessionLine", rows)

      # @return [Array<Hash>] the sessions, each with `id`, `name`, `status`, `state`, `detail`,
      #   `started`, `ended` and the `work_item` it was dispatched for
      def rows
        runs = ledger
        found = Dir.glob(File.join(@dir, "*", "state.json")).filter_map { |path| session(path, runs) }
        found.sort_by { |row| [row[:status] == "busy" ? 0 : 1, row[:started].to_s] }.reverse
      end

      private

      # The ledger's runs by session id; empty when it cannot be read.
      def ledger
        @runs.call
      rescue PipelineBoard::Unavailable
        {}
      end

      # What a ledger run says of its session, in the shape the status rules read: `state` is the
      # condition its last check recorded (absent before the first check), `status` is `busy`
      # while it works, `started` is when it began.
      def agent_of(ran)
        return unless ran

        condition = ran[:condition].to_s
        { "name" => ran[:run].to_s, "state" => (condition unless condition.empty?),
          "status" => condition == "working" ? "busy" : "idle", "started" => ran[:started_at].to_s }
      end

      def session(path, runs)
        id = File.basename(File.dirname(path))
        age = @now.call - File.mtime(path)
        return if outside_window?(age) && !runs.key?(id)

        build(id, JSON.parse(File.read(path)), runs[id], age, File.join(File.dirname(path), "timeline.jsonl"))
      rescue JSON::ParserError, SystemCallError
        nil
      end

      def outside_window?(age) = age > PipelineBoard::Rules.setting("session_window_hours") * 3600

      def build(id, state, ran, age, timeline)
        agent = agent_of(ran)
        edges = edges_of(timeline)
        status = status_of(state, agent, age)
        row = { id: id, name: name_of(id, agent, state), status: status, state: live_state(state, agent),
                detail: state["detail"].to_s.slice(0, 140), started: stamp(agent, edges),
                ended: ended_of(status, edges), idle_seconds: age.round }
        row.merge(ran_of(ran || {})).merge(context_of(status, state))
      end

      # The permission mode a session was launched with, from its respawn flags, or nil when none.
      def permission_of(state)
        flags = Array(state["respawnFlags"])
        index = flags.index("--permission-mode")
        index && flags[index + 1]
      end

      # What a blocked session waits on: its transcript's last words and steps, and the links its
      # job lists (pull requests and the like). Other sessions carry nothing extra.
      def context_of(status, state)
        return {} unless status == "blocked"

        { context: PipelineBoard::SessionContext.of(state["linkScanPath"].to_s).merge(context_extras(state)),
          resume: state.values_at("resumeSessionId", "sessionId").compact.first, cwd: state["cwd"].to_s,
          permission: permission_of(state), attach: state["daemonShort"].to_s,
          question_kind: question_kind(state) }
      end

      # @return [String] the kind the job names, else the one its question begins with, else empty
      def question_kind(state)
        named = state["questionKind"].to_s
        named.empty? ? state["detail"].to_s[KIND_PREFIX, 1].to_s.downcase : named
      end

      # The links the job lists, the git branch the session works on in its own worktree, what it
      # says it needs from a person, and the reply Claude Code suggests for it (`suggestedReply`).
      def context_extras(state)
        { links: Array(state["children"]), branch: state["worktreeBranch"].to_s, needs: state["needs"].to_s.strip,
          suggested: state["suggestedReply"].to_s.strip }
      end

      def ended_of(status, edges) = %w[busy blocked].include?(status) ? nil : edges.last

      # The AgentRun behind a session: its work item, run key and repo, empty when none is known,
      # and `superseded_by` the session the run follows now, for one the run held before it forked.
      # `parent` is the run that dispatched it, empty when none did.
      def ran_of(ran)
        { work_item: ran[:work_item].to_s, run: ran[:run].to_s, repo: ran[:repo].to_s, agent: ran[:agent].to_s,
          works_as: ran[:works_as].to_s, superseded_by: ran[:superseded_by].to_s, parent: ran[:parent].to_s }
      end

      # The name the job recorded, else its run key, else the id.
      def name_of(id, agent, state)
        [state["name"], agent && agent["name"]].map(&:to_s).find { |name| !name.empty? } || id
      end

      # A session is `blocked` when its job says so and it is still alive: it waits on a person.
      # A session with a ledger run reports the condition its last check recorded, which is current
      # even while its state file still says blocked from before a reply. The file decides only
      # when the run has none.
      # A session is blocked only when it waits on a person, which its job says by setting `needs`.
      # A session paused on a push or CI is still working, so it is shown busy, not blocked.
      def status_of(state, agent, age)
        word = live_state(state, agent)
        fresh = age < PipelineBoard::Rules.setting("session_fresh_seconds")
        PipelineBoard::Rules.verdict("Session status", session_measures(state, agent, word, fresh))
      end

      # What the `Session status` rows compare, as 1 or 0.
      def session_measures(state, agent, word, fresh)
        { waiting: flag(blocked_state?(word, agent, fresh)), needs: flag(waiting_on_person?(state) && (!agent.nil? || fresh)),
          busy: flag(busy?(word, agent, fresh)), failed: flag(%w[failed error].include?(word)) }
      end

      def flag(condition) = condition ? 1 : 0

      # The job says it is blocked, and it is listed or recently written.
      def blocked_state?(word, agent, fresh) = word == "blocked" && (!agent.nil? || fresh)

      def waiting_on_person?(state) = !state["needs"].to_s.strip.empty?

      def live_state(state, agent)
        (agent && agent["state"]) || state["state"].to_s
      end

      def busy?(word, agent, fresh) = (agent && agent["status"] == "busy") || (word == "working" && fresh)

      def stamp(agent, edges)
        started = agent && agent["started"].to_s
        started.nil? || started.empty? ? edges.first : started
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
