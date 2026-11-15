# frozen_string_literal: true

require "json"
require_relative "console_capture"
require_relative "started_work"
require_relative "ci_seeing/listing"
require_relative "ci_seeing/pace"
require_relative "main_integration/command_runner"

module Hecks
  module Adapters
    # The `Seeing` port's adapter for `CiLook`: reads, through `gh`, the CI runs of main and of the
    # push train's pull requests, and answers each in a state no `CiRunRecord` holds yet: an
    # attempt seen going, or seen completed with its jobs. It asks GitHub at most once in
    # {Pace::EVERY} seconds, reads the jobs of a few completed runs a look so a first look over
    # many runs stays short, and writes nothing but the listing {Pace} keeps: the bluebook's
    # policy records what it answers.
    class CiSeeing
      # The aggregate whose records say what is already held.
      RECORD = "CiRunRecord"
      # How many completed runs one look reads the jobs of and answers. The rest wait for a later
      # look, newest first.
      JOBS_A_LOOK = 6

      # @param registry [Runtime::Registry, nil] the booted registry whose records are read
      # @param aggregate [Bluebook::Aggregate, nil] `CiLook`; unused
      # @param settings [Hash] `gh:` stands in for the `gh` call, `pace:` for the {Pace}
      # @param root [String, nil] the checkout `gh` runs in
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
        @checkout = root || Dir.pwd
        @listing = Listing.new(settings[:gh] || method(:gh))
        @pace = settings[:pace] || Pace.new
      end

      # @param run [Hash, String] the look that asks, as its key or the key's value
      # @return [Array<Hash>] one `Sighting` row per listed run in a state no record holds: every
      #   run still going, and the newest few completed ones with their jobs
      def unrecorded(run:)
        held = recorded
        fresh = listed(plain(run).to_s).reject { |row| held.include?(row[:sighting]) }
        done, going = fresh.partition { |row| row[:state] == "completed" }
        going + done.first(JOBS_A_LOOK).map { |row| @listing.with_jobs(row) }
      end

      private

      # The listing, each row keyed as its record would be and carrying the look that asks.
      def listed(look)
        @pace.listing { @listing.rows }.map { |row| row.merge(id: look, sighting: key(row)) }
      end

      # A record's key: the run, the attempt, and whether it was going or done when it was seen.
      def key(row) = "#{row[:ci_run]}-#{row[:attempt]}-#{row[:state] == "completed" ? "done" : "going"}"

      # @return [Array<String>] the key of every record held; none when they are not readable
      def recorded
        book = @registry&.bluebook("Hecks")
        aggregate = book&.aggregates&.find { |candidate| candidate.hecks_name == RECORD }
        return [] unless aggregate

        @registry.repository("Hecks", aggregate).all.map { |held| StartedWork.value(held, :sighting).to_s }
      end

      def gh(*args)
        ok, output = MainIntegration::CommandRunner.new.call(["gh", *args], chdir: @checkout)
        raise ConsoleCapture::Failure, "gh #{args.first(2).join(" ")} failed: #{output.to_s.strip}" unless ok

        JSON.parse(output)
      rescue JSON::ParserError
        raise ConsoleCapture::Failure, "gh #{args.first(2).join(" ")} answered no JSON"
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
