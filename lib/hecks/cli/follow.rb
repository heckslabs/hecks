# frozen_string_literal: true

require "json"
require "optparse"
require_relative "../../hecks"

module Hecks
  module CLI
    # The command behind `hecks follow`: live-tails a domain's persisted event log as JSON lines.
    #
    # Events are one table per domain, so this polls the first repository that answers `:events`
    # and diffs its size each tick, filtering client-side when `--aggregate` is given.
    module Follow
      module_function

      # Tails until interrupted.
      #
      # @param argv [Array<String>] `<domain> [--aggregate name] [--interval seconds] [--from-now]`
      # @param program [String] the name the usage message calls this command by
      # @return [void]
      # @raise [SystemExit] when no domain is named or no adapter persists an event log
      def call(argv, program: "hecks follow")
        argv = argv.dup
        domain_name = argv.shift or abort "usage: #{program} <domain> [options]"
        options = parse(argv, program)
        repository = event_repository(Hecks.boot(domain_name), domain_name, program)
        tail(repository, options)
      end

      # @param argv [Array<String>] the options after the domain; consumed in place
      # @param program [String] the name the usage banner calls this command by
      # @return [Hash] `:interval`, `:from_now` and, when given, `:aggregate`
      def parse(argv, program)
        options = { interval: 0.5, from_now: false }
        OptionParser.new do |parser|
          parser.banner = "usage: #{program} <domain> [options]"
          parser.on("-a", "--aggregate=NAME", "Only follow events for this aggregate (e.g. Order)") do |name|
            options[:aggregate] = name
          end
          parser.on("-i", "--interval=SECONDS", Float, "Poll interval in seconds (default: 0.5)") { |v| options[:interval] = v }
          parser.on("--from-now", "Skip existing events; only print ones emitted from now on") { options[:from_now] = true }
        end.parse!(argv)
        options
      end

      # @param runtime [Runtime] a booted domain
      # @param domain_name [String] its name, for the refusal
      # @param program [String] the name the refusal calls this command by
      # @return [Object] the first repository that answers `:events`
      # @raise [SystemExit] when none does
      def event_repository(runtime, domain_name, program)
        repositories = runtime.registry.bluebooks.flat_map do |bluebook_domain, bluebook|
          bluebook.aggregates.map { |aggregate| runtime.registry.repository(bluebook_domain, aggregate) }
        end
        repositories.find { |repo| repo.respond_to?(:events) } or
          abort "#{program}: no adapter in #{domain_name} persists an event log"
      end

      # Says whether `event` passes the `--aggregate` filter: a bare name matched
      # case-insensitively, or the exact name.
      #
      # @param event [Object] a logged event
      # @param filter [String, nil] the aggregate name asked for
      # @return [Boolean]
      def matches?(event, filter)
        filter.nil? || event.aggregate.to_s.split("::").last.casecmp?(filter) || event.aggregate == filter
      end

      # @param repository [Object] answers `events`
      # @param options [Hash] the parsed options
      # @return [void]
      def tail(repository, options)
        seen = options[:from_now] ? repository.events.size : 0
        $stdout.sync = true
        trap("INT") { exit }

        loop do
          events = repository.events
          if events.size > seen
            events[seen..].each { |event| puts JSON.generate(event.to_h) if matches?(event, options[:aggregate]) }
            seen = events.size
          end
          sleep options[:interval]
        end
      end
    end
  end
end
