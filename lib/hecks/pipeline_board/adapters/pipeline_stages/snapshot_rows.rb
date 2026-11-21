# frozen_string_literal: true

require_relative "../rules"
require_relative "readings"
require_relative "stuck_rows"
require_relative "run_rows"
require_relative "board_reads"

module Hecks
  module Adapters
    module PipelineBoard
      # The board's state as the bluebook's one `Snapshot` row: the stages, the readings, what is
      # stuck, the roles, the runs, the open train pull requests, the release and the newest
      # events. It reshapes what the state already holds and reads nothing itself.
      module SnapshotRows
        # How many events the snapshot carries.
        EVENTS = 40

        # A `TrainCard` and a `ReleaseCard` with nothing read: the runtime keeps a row nested in
        # the `Snapshot` as it was answered, so every field is answered here.
        TRAIN = { pr: 0, head_sha: "", commits: 0, green: 0, red: 0, skipped: 0, red_jobs: "", auto_merge: "",
                  age: "", state: "unknown", superseded: "" }.freeze
        RELEASE = { latest_tag: "", next_version: "", changelog_heading: "", stable_has_version_commit: "",
                    holds: "" }.freeze

        module_function

        # @param state [Hash] the board's state: `generated_at`, `stages`, `metrics`, `sessions`,
        #   `roles` and `events`
        # @param extras [Hash] `train_prs:`, `release:` and `turns:` as their readers answered
        # @return [Hash] one `Snapshot` row
        def build(state, extras = {})
          at = state[:generated_at].to_s
          { generated_at: at, stale_seconds: 0, events: events(listed(state[:events])) }
            .merge(numbers(state, at), people(state, extras), shipping(extras), extras.fetch(:reads) { BoardReads.build({}, at) })
        end

        # @return [Hash] the stages, the readings and the roles: every number, one key each
        def numbers(state, at)
          { stages: Readings.stages(listed(state[:stages]), at), readings: Readings.tiles(listed(state[:metrics]), at),
            roles: roles(listed(state[:roles]), at) }
        end

        # @return [Hash] what is stuck and the runs, both read from the sessions
        def people(state, extras)
          sessions = listed(state[:sessions])
          { stuck: StuckRows.of(state, sessions), runs: RunRows.of(sessions, listed(extras[:turns])) }
        end

        # @return [Hash] the open train pull requests and the release
        def shipping(extras)
          { train: trains(listed(extras[:train_prs])), release: release(extras[:release]) }
        end

        # @return [Array] the section when it was read as a list, else none
        def listed(section) = section.is_a?(Array) ? section : []

        # @return [Array<Hash>] one `Reading` per role: its live sessions, and those working now
        def roles(cards, at)
          cards.map do |card|
            working = Array(card[:working]).map { |session| session[:name] }.join(", ")
            { key: "role_#{card[:name]}", label: card[:name].to_s, value: card[:live].to_s, unit: "live",
              state: Rules.verdict("Role", { live: card[:live] }), note: working }.merge(Readings.read("role", at))
          end
        end

        # @return [Array<Hash>] one `TrainCard` per open train pull request: its checks counted
        #   and its state by the `Train PR` rows; the board reads no commits or red jobs for one yet
        def trains(pulls)
          pulls.map do |pull|
            red = pull[:failed].to_i
            TRAIN.merge(pr: pull[:number].to_i, head_sha: pull[:branch].to_s, green: pull[:passed].to_i, red: red,
                        state: Rules.verdict("Train PR", { red: red, pending: pull[:pending].to_i }))
          end
        end

        # @return [Hash] the `ReleaseCard`: the latest tag when the release was read
        def release(read)
          RELEASE.merge(latest_tag: read.is_a?(Hash) ? read[:tag].to_s : "")
        end

        # @return [Array<Hash>] the newest events as `EventLine` rows
        def events(rows) = rows.first(EVENTS).map { |row| event(row) }

        # @return [Hash] one `EventLine`: the policies that reacted are named, separated by a comma
        def event(row)
          reacted = Array(row[:reactions]).map { |reaction| reaction[:policy] }.join(", ")
          { at: row[:at].to_s, aggregate: row[:aggregate].to_s, id: row[:id].to_s, name: row[:name].to_s,
            source: row[:source].to_s, reactions: reacted }
        end
      end
    end
  end
end
