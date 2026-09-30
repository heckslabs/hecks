# frozen_string_literal: true

require "json"
require_relative "../../../hecks"
require_relative "../../ports/persistence/plugins/era"
require_relative "../../fuzzing/concurrent_dispatch"

module Hecks
  module QualityControlCli
    # The command behind `bin/qa_concurrency_racer`: one racer of
    # `Hecks::Fuzzing::ConcurrentDispatch`, run as its own OS process.
    #
    # It is spawned, not forked: the caller (`bin/qa_sweep`) holds live `PostgresEra` connections,
    # and fork duplicates their file descriptors and SSL state, corrupting them when a child exits.
    #
    #   bin/qa_concurrency_racer <domain-path> <database> <schema> <verb> <args-json>
    #
    # It prints one line, `succeeded`, `refused` or `crashed:<class>: <message>`, and always exits
    # 0.
    class QaConcurrencyRacer
      USAGE = "usage: bin/qa_concurrency_racer <domain-path> <database> <schema> <verb> <args-json>"

      # Dispatches the one step and prints how it went.
      #
      # @param argv [Array<String>] the domain path, database, schema, verb and args JSON
      # @param root [String] unused; a racer needs no checkout of its own
      # @param out [IO] where the outcome goes
      # @return [Integer] 0 always
      # @raise [SystemExit] with the usage line when an argument is missing
      def self.call(argv, root: nil, out: $stdout)
        domain_path, database, schema, verb, args_json = argv
        abort USAGE unless domain_path && database && schema && verb && args_json

        step = { "verb" => verb, "args" => JSON.parse(args_json) }
        outcome = Hecks::Fuzzing::ConcurrentDispatch.boot_preserving_schema(domain_path, database: database,
                                                                                         schema:   schema) do |copy|
          Hecks::Fuzzing::ConcurrentDispatch.dispatch_one(Hecks.boot(copy), step)
        end
        out.puts outcome
        0
      end
    end
  end
end
