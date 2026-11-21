# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # The rows of the staged bad day ({BadDay}): the strip, the tiles, the sessions, what is
      # stuck and the newest events.
      module BadDayRows
        RED = "main is red since 13:41: episode red-episode-0f3a91c2, revert 51d0aa37e4 in CI"
        CLOSED = "admission closed: load 14.2 of 12.0, short"

        module_function

        # @return [Array<Hash>] the strip, left to right
        def strip
          [stage("Work items", "attention", "412", "14 could start, none did"),
           stage("Sessions", "attention", "9", "9 busy, 3 blocked on you, 2 standing too long"),
           stage("Fill", "attention", "closed", CLOSED),
           stage("Local main", "ok", "7c41e09b2", "clean; 0 ahead, 0 behind origin/main"),
           stage("Integration", "failed", "1", "landings refuse: #{RED}"),
           stage("Train", "failed", "7", "train PR #1903: 7 red jobs; landings and trains refuse"),
           stage("CI", "failed", "red", RED),
           stage("Promote", "ok", "0", "stable 3e1378f36; 0 commits behind main"),
           stage("Release", "ok", "v7.0.0", "published 3 days ago")]
        end

        def stage(name, state, count, detail) = { name: name, state: state, count: count, detail: detail }

        # @return [Hash{Symbol => Object}] every section but the strip and the typed board
        def sections(at)
          { generated_at: at, metrics: metrics, fanout: fanout(at), live_store_problem: nil, stale_sections: {},
            load_guard: nil, sessions: sessions(at), events: events(at), roles: [], daily_health: { line: "staged" } }
            .merge(unstaged(%i[ci_runs slowest_jobs train_ci_runs train_slowest_jobs train_flakes open_work pruning reviews
                               integration throughput_days cycles]))
        end

        def unstaged(keys) = keys.to_h { |key| [key, { unknown: "the staged bad day does not stage this" }] }

        def metrics
          [metric("ci", "CI", nil, "", ["failed", RED]),
           metric("working", "Dispatched sessions", 9, "of 10", ["attention", CLOSED]),
           metric("disk", "Disk free", 41.2, "GB", ["ok", "91% of 460.4 GB used"]),
           metric("open_prs", "Open PRs", 30, "open (limit)", ["attention", "oldest 30.2 h; train PR #1903"])]
        end

        def metric(id, label, value, unit, reading)
          { id: id, label: label, value: value, unit: unit, state: reading[0], detail: reading[1], trend: nil }
        end

        def fanout(at) = { rows: [], flags: [CLOSED], fill: { unknown: "admission is closed" }, sessions: sessions(at) }

        # @return [Array<Hash>] three waiting on a person, then six at work, two standing too long
        def sessions(at)
          busy = [5400, 4800, 30, 20, 12, 8].each_with_index.map { |idle, index| ["coder-#{index + 1}", idle] }
          waiting.map { |row| session(row[:id], "blocked", row[:what], at, 600) } +
            busy.map { |id, idle| session(id, "busy", "working", at, idle) }
        end

        def session(id, status, detail, at, idle)
          { id: id, name: id, status: status, state: status == "busy" ? "working" : status, detail: detail, started: at,
            ended: nil, idle_seconds: idle, work_item: "", run: "", works_as: "coder", owner: status == "blocked" }
        end

        # @return [Array<Hash>] the three entries waiting on a person
        def waiting
          [{ id: "w-1", what: "[owner] Shape ledger accepts a live-store change?", waits_on: "the owner" },
           { id: "w-2", what: "[choose] Two migrations rename the same column", waits_on: "the orchestrator" },
           { id: "w-3", what: "[confirm] Mark the revert item done on the strength of CI?", waits_on: "the orchestrator" }]
        end

        # @return [Hash] the typed board: the strip as stages, what is stuck, the train
        def board(at)
          { generated_at: at, stale_seconds: 0, events: events(at), stages: typed(at), readings: [], roles: [], runs: [],
            stuck: stuck(at), train: [train], release: {} }
        end

        def typed(at)
          strip.each_with_index.map do |row, index|
            { key: row[:name].downcase.tr(" ", "_"), label: row[:name], value: row[:count], unit: "", state: row[:state],
              note: row[:detail], order: index + 1, since: "", link: "", source: "staged", fresh_at: at }
          end
        end

        def stuck(at)
          [stuck_row("red_main", RED, "main is red", "CI on main"), *waiting.map { |row| waiting_row(row) },
           stuck_row("overdue", "coder-1 idle 90 minutes", "standing too long", "a session"),
           stuck_row("overdue", "coder-2 idle 80 minutes", "standing too long", "a session")].map { |row| row.merge(since: at) }
        end

        def waiting_row(row) = stuck_row("blocked_run", row[:what], "waiting on a person", row[:waits_on])

        def stuck_row(kind, what, group, waits)
          { kind: kind, what: what, group: group, waits_on: waits, owner_run: "", link: "" }
        end

        def train
          { pr: 1903, head_sha: "train/main-7c41e09b2a", commits: 3, green: 70, red: 7, skipped: 0,
            red_jobs: "rspec_ruby (shard b)", auto_merge: "", age: "", state: "failed", superseded: "" }
        end

        # @return [Array<Hash>] the newest events, newest first
        def events(at)
          [["Hecks::RedFlag", "RedFlagRaised", []], ["Hecks::Landing", "LandingRefused", [{ policy: "RefuseWhenRed" }]],
           ["Hecks::AgentRun", "AgentBlocked", []]].map do |aggregate, name, reactions|
            { key: "staged:#{name}", source: "staged", at: at, aggregate: aggregate, id: "staged", name: name,
              reactions: reactions, links: {}, correlation: {} }
          end
        end
      end
    end
  end
end
