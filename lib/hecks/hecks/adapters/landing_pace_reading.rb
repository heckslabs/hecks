# frozen_string_literal: true

require "hecks"
require "time"
require_relative "journal_store/readings/event_trace/sqlite_reader"
require_relative "landing_pace_reading/ledger"
require_relative "landing_pace_reading/pairing"
require_relative "landing_pace_reading/report"
require_relative "landing_pace_reading/throughput"
require_relative "git"

module Hecks
  module Adapters
    # The `Pace` port's adapter for `LandingPace`: how many branches landed each day and how long
    # each waited from ready to landed, read from the event table of the SQLite file the delivery
    # package's `Landing` is kept in. The file is opened read-only and nothing is written.
    class LandingPaceReading
      # The names a landing's events are stored under: the delivery package's, and the Hecks
      # domain's for a checkout whose `Landing` is declared there. No record has events under both.
      LANDINGS = %w[Delivery::Landing Hecks::Landing].freeze

      # Days measured when the query names none.
      DAYS = 14

      # Hours measured when a throughput names none.
      HOURS = 24

      # The answer when `Landing` is kept in Memory or its file does not exist.
      NO_LEDGER = "no ledger to measure: Landing is not kept in a SQLite file here"

      # @param registry [Runtime::Registry, nil] the booted registry whose `Landing` binding is read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
      end

      # @param held [Hash] the query's `days`, the length of the window (14 when absent)
      # @return [Hash{Symbol => String}] `text:` the landings of each day, then the totals and
      #   the wait from ready to landed
      def pace(**held)
        days = plain(held[:days]).to_i
        days = DAYS unless days.positive?
        path = Ledger.path(@registry)
        { text: path ? measured(path, days) : NO_LEDGER }
      end

      # @param held [Hash] the query's `hours`, the length of the window (24 when absent)
      # @return [Hash{Symbol => String}] `text:` the branches landed in the window and how many
      #   of them `origin/main` contains
      def throughput(**held)
        hours = plain(held[:hours]).to_i
        hours = HOURS unless hours.positive?
        path = Ledger.path(@registry)
        { text: path ? counted(path, hours) : NO_LEDGER }
      end

      private

      def counted(path, hours)
        reader = JournalStore::Readings::EventTrace::SqliteReader.open(path)
        since = (Time.now.utc - (hours * 3600)).iso8601
        landed = Pairing.new(reader.window(LANDINGS, since)).landed
        Throughput.new(landed, hours: hours, shipped: ->(sha) { Git.new.ancestor?(sha, "origin/main") }).text
      ensure
        reader&.close
      end

      def measured(path, days)
        reader = JournalStore::Readings::EventTrace::SqliteReader.open(path)
        since = (Time.now.utc - (days * 86_400)).iso8601
        Report.new(Pairing.new(reader.window(LANDINGS, since)), days: days, source: path).text
      ensure
        reader&.close
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
