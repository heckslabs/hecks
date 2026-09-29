# frozen_string_literal: true

require "json"
require_relative "console_capture"
require_relative "../../cli/run"
require_relative "../../cli/model_check"
require_relative "../../cli/smoke_test"
require_relative "../../cli/behaviors"
require_relative "../../cli/refresh_projections"

module Hecks
  module Adapters
    # What the `DomainRuntime` port's adapter does when a journaled Custodian command asks it to:
    # the asks of `ModelCheckRun` and `Operation`, plus the `Follow` query.
    #
    # An ask is handed the whole record it was made on (its `held_state`), so each method reads the
    # record's fields, runs the existing `Hecks::CLI::*` entry point captured, and answers the text
    # it printed. An answer records a success; a raise records a refusal, so a check that finds
    # something, or a run that fails, is refused with the report as its reason.
    module InProcessOperations
      # The chapters `bin/model_check` and `hecks model_check` sweep when no domain is named need a
      # checkout; an installed gem has none.
      CHECKOUT_MARKER = "hecks.gemspec"

      # Longest a `Follow` query may wait for new entries, so one call cannot hold a launcher open.
      MAX_FOLLOW_WAIT = 60

      # Runs the static analysis over the named domains, or over the whole corpus in a checkout.
      #
      # @param held [Hash] the `ModelCheckRun` record: `domains` (comma separated paths), `strict`
      #   and `profile`
      # @return [Hash{Symbol => Hash}] `report:` the analysis as printed
      # @raise [ConsoleCapture::Failure] when a finding was left, or the analysis could not run
      def check(**held)
        argv = plain(held[:domains]).to_s.split(",").map(&:strip).reject(&:empty?)
        missing = argv.reject { |domain| File.exist?(domain) }
        raise Runtime::NotFound, "no such domain #{missing.first.inspect}" if missing.any?

        argv.unshift("--strict") if plain(held[:strict])
        argv.unshift("--profile", plain(held[:profile]).to_s) if present?(held[:profile])

        text = ConsoleCapture.answer do
          CLI::ModelCheck.call(argv, program: "hecks model_check", root: checkout_root)
        end
        { report: { value: text } }
      end

      # Dispatches one verb, or executes a step list, against a domain.
      #
      # @param held [Hash] the `Operation` record: `subject` (the domain), then `script`, or
      #   `verb` with `arguments` (its `name=value` words)
      # @return [Hash{Symbol => Hash}] `output:` what the run reported
      # @raise [ConsoleCapture::Failure] when the verb was refused or an expectation was unmet
      def execute(**held)
        argv = [plain(held[:subject])].compact
        script = plain(held[:script])
        argv += script ? [script] : [plain(held[:verb]), *words(held[:arguments])].compact

        output(ConsoleCapture.answer { CLI::Run.call(argv, program: "hecks run") })
      end

      # Forces every read-model projection the domain declares to catch up.
      #
      # @param held [Hash] the `Operation` record: `subject` (the domain)
      # @return [Hash{Symbol => Hash}] `output:` how many projections were refreshed
      # @raise [Runtime::NotFound] if the domain cannot be found
      def refresh(**held)
        count = CLI::RefreshProjections.call(boot(held[:subject]))
        output("refreshed #{count} projection(s)")
      end

      # Runs a `.behaviors` file, or every one under a directory.
      #
      # @param held [Hash] the `Operation` record: `subject` (the file or directory)
      # @return [Hash{Symbol => Hash}] `output:` the per-test report
      # @raise [ConsoleCapture::Failure] when any test failed, errored or did not parse
      def verify(**held)
        argv = [plain(held[:subject])].compact
        output(ConsoleCapture.answer { CLI::Behaviors.call(argv, program: "hecks run_behaviors") })
      end

      # Boots a wired domain and dispatches one synthesized call per command and report.
      #
      # @param held [Hash] the `Operation` record: `subject` (the domain; the enclosing one when
      #   absent and this is not a checkout)
      # @return [Hash{Symbol => Hash}] `output:` the per-domain report
      # @raise [ConsoleCapture::Failure] when any dispatch failed
      def smoke(**held)
        domain = plain(held[:subject]) || (checkout_root ? nil : Folder.new.domain_root)
        argv = [domain].compact

        output(ConsoleCapture.answer { CLI::SmokeTest.call(argv, root: checkout_root || Dir.pwd) })
      end

      # A domain's event log past a cursor, waiting up to `wait` seconds for the first entry.
      # A launcher answers once, so a follow is a bounded poll: pass the answered `cursor` back
      # as `since` to keep tailing.
      #
      # @param domain [Hash, String] a domain directory
      # @param aggregate [Hash, String, nil] only entries of this aggregate, by bare name
      # @param since [Hash, Integer, nil] how many entries were already seen; all when absent
      # @param from_now [Hash, Boolean, nil] skip what exists; answer only a cursor at its end
      # @param wait [Hash, Integer, nil] seconds to wait for a new entry, at most 60
      # @param interval [Hash, Float, nil] seconds between polls
      # @return [Hash] `cursor:` the count to pass as `since`, and `events:` the entries
      # @raise [Runtime::NotFound] if the domain cannot be found or keeps no event log
      def follow(domain:, aggregate: nil, since: nil, from_now: nil, wait: nil, interval: nil)
        repository = event_repository(domain)
        seen = plain(since)&.to_i || (plain(from_now) ? repository.events.size : 0)
        limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + [plain(wait).to_f, MAX_FOLLOW_WAIT].min

        loop do
          events = repository.events
          fresh  = (events[seen..] || []).select { |event| followed?(event, plain(aggregate)) }
          seen   = events.size
          done   = Process.clock_gettime(Process::CLOCK_MONOTONIC) >= limit
          return { cursor: seen, events: fresh.map { |event| JSON.parse(JSON.generate(event.to_h)) } } if fresh.any? || done

          sleep((plain(interval) || 0.5).to_f)
        end
      end

      private

      def output(text) = { output: { value: text } }

      def present?(argument) = !plain(argument).to_s.empty?

      # A list of value objects or bare strings, as plain strings.
      def words(list) = Array(list).map { |word| plain(word) }

      # The repository root when this is a hecks checkout: `hecks.gemspec` sits beside `lib/`.
      def checkout_root
        root = File.expand_path("../../../..", __dir__)
        root if File.exist?(File.join(root, CHECKOUT_MARKER))
      end

      def event_repository(domain)
        registry = boot(domain).registry
        repositories = registry.bluebooks.flat_map do |name, bluebook|
          bluebook.aggregates.map { |aggregate| registry.repository(name, aggregate) }
        end
        repositories.find { |repository| repository.respond_to?(:events) } or
          raise Runtime::NotFound, "no adapter in #{plain(domain)} persists an event log"
      end

      # Says whether `event` passes the aggregate filter: a bare name, case-insensitive, or exact.
      def followed?(event, filter)
        filter.nil? || event.aggregate.to_s.split("::").last.casecmp?(filter) || event.aggregate == filter
      end
    end
  end
end
