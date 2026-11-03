# frozen_string_literal: true

require "json"
require "time"
require "hecks/hecks/adapters/journal_store/readings/sqlite_status/read_only"

module Hecks
  module Adapters
    # The `Tally` port's adapter for `Detection`: counts the tool calls the Catcher's sittings
    # kept, by subject, and answers the subject that recurs most among those no audit concerns.
    #
    # It only reads: the store is opened read-only, and nothing is written to it or beside it.
    # It does not decide what recurs. The bluebook compares the answer to its thresholds.
    class PatternTally
      # Opens a store file so that reading it creates nothing beside it.
      ReadOnly = JournalStore::Readings::SqliteStatus::ReadOnly

      # Where the Catcher world keeps its records, when the settings name no other path.
      DEFAULT_PATH = "~/.claude/hecks-dev/catcher.db"

      # A word of a subject: the run of letters and digits a name is built from.
      WORD = /[A-Za-z0-9]+/

      # What the adapter answers when no subject is left: no calls, no sessions, no text.
      NOTHING = { subject: "", calls: 0, sessions: 0, success_rate: 0.0, proposal: "",
                  proposed_kind: "", aggregate_name: "", raised_at: "" }.freeze

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `path:` the Catcher store (default {DEFAULT_PATH})
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @path = File.expand_path(settings[:path] || DEFAULT_PATH)
      end

      # Tallies the kept calls by subject and picks the best subject no audit concerns: most
      # sessions, then most calls, then the subject's name.
      #
      # @param run [Hash, String, nil] the detection's run key; unused
      # @return [Hash{Symbol => Hash}] each answer as `{ value: }`: `subject`, `calls`,
      #   `sessions`, `success_rate` (rounded to 2 places), `proposal`, `proposed_kind`,
      #   `aggregate_name` and `raised_at`. When nothing recurs the counts are 0 and the
      #   strings are empty.
      # @raise [SQLite3::Exception] when the store exists and cannot be read
      def tally(run: nil, **_held)
        best = candidates.min_by { |row| [-row[:sessions], -row[:calls], row[:subject]] }
        wrapped(best ? answer(best) : NOTHING)
      end

      private

      def answer(best)
        best.merge(proposal: proposal(best[:subject]), proposed_kind: "aggregate",
                   aggregate_name: words(best[:subject]).first, raised_at: now)
      end

      def wrapped(row) = row.transform_values { |value| { value: value } }

      def candidates
        groups = calls.group_by { |call| call[:subject] }.except(*subjects)
        groups.map { |name, group| summary(name, group) }
      end

      def summary(name, group)
        done = group.count { |call| call[:succeeded] }
        { subject: name, calls: group.size, sessions: group.map { |c| c[:observed_in] }.uniq.size,
          success_rate: (done.to_f / group.size).round(2) }
      end

      def calls
        rows("observation", "calls").flat_map { |raw| decode(raw) || [] }
                                    .select { |call| call.is_a?(Hash) && call[:subject].to_s != "" }
      end

      def subjects = rows("audit", "subject").filter_map { |raw| plain(decode(raw)) }

      def rows(table, column)
        return [] unless File.file?(@path)

        db = ReadOnly.open(@path)
        exists = db.get_first_value("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", table)
        exists ? db.execute(%(SELECT "#{column}" FROM "#{table}")).map(&:first) : []
      ensure
        db&.close
      end

      def decode(raw)
        JSON.parse(raw.to_s, symbolize_names: true)
      rescue JSON::ParserError
        raw
      end

      def plain(value) = value.is_a?(Hash) ? value[:value] : value

      def proposal(subject)
        names = words(subject)
        command = names.size > 1 ? names.drop(1).join : names.first
        <<~DSL.chomp
          aggregate "#{names.first}" do
            command "#{command}" do
              role "Operator"
              goal "Run `#{subject}`"
            end
          end
        DSL
      end

      def words(subject)
        found = subject.to_s.scan(WORD).map { |word| word[0].upcase + word[1..] }
        found.empty? ? ["Action"] : found
      end

      def now = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end
  end
end
