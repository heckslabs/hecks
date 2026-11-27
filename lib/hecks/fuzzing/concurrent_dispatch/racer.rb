# frozen_string_literal: true

require "json"
require_relative "../../../hecks"
require_relative "../../ports/persistence/plugins/era"
require_relative "../concurrent_dispatch"

module Hecks
  module Fuzzing
    module ConcurrentDispatch
      # One racer of {ConcurrentDispatch}, run as its own OS process.
      #
      # It is spawned, not forked: the caller holds live `PostgresEra` connections, and fork
      # duplicates their file descriptors and SSL state, corrupting them when a child exits.
      #
      #   ruby -Ilib -e '...Racer.call(ARGV, out: $stdout)' -- \
      #     <domain-path> <database> <schema> <verb> <args-json>
      #
      # `Racing#racer_argv` builds that line.
      #
      # It prints one line, `succeeded`, `refused` or `crashed:<class>: <message>`, and always exits
      # 0.
      class Racer
        USAGE = "usage: racer <domain-path> <database> <schema> <verb> <args-json>"

        # Dispatches the one step and prints how it went.
        #
        # @param argv [Array<String>] the domain path, database, schema, verb and args JSON
        # @param out [IO] where the outcome goes: the caller's standard output
        # @return [Integer] 0 always
        # @raise [SystemExit] with the usage line when an argument is missing
        def self.call(argv, out:)
          domain_path, database, schema, verb, args_json = argv
          abort USAGE unless domain_path && database && schema && verb && args_json

          step = { "verb" => verb, "args" => JSON.parse(args_json) }
          outcome = ConcurrentDispatch.boot_preserving_schema(domain_path, database: database, schema: schema) do |copy|
            ConcurrentDispatch.dispatch_one(Hecks.boot(copy), step)
          end
          out.puts outcome
          0
        end
      end
    end
  end
end
