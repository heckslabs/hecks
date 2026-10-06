# frozen_string_literal: true

require "etc"
require_relative "../../tools"

module Hecks
  module Tools
    module FuzzSweep
      # The command line of a sweep: its options, and what the chosen adapter needs.
      module Options
        # @param args [Array<String>] the command line, consumed
        # @return [Hash, nil] `seeds`, `steps`, `workers`, `adapter` and `domain`; nil after a
        #   refusal
        def parse(args)
          options = { seeds: 20, steps: 30, workers: nil, adapter: :memory, domain: nil }
          until args.empty?
            apply_option(options, args.shift, args)
            return nil unless adapter_known?(options[:adapter])
          end
          options
        end

        # Records one command-line word in `options`, taking its value from `rest` when it has one.
        def apply_option(options, arg, rest)
          case arg
          when "--seeds" then options[:seeds] = Integer(rest.shift)
          when "--steps" then options[:steps] = Integer(rest.shift)
          when "--workers" then options[:workers] = Integer(rest.shift)
          when "--adapter" then options[:adapter] = rest.shift.to_s.downcase.to_sym
          else options[:domain] = arg
          end
        end

        # @return [Boolean] whether `adapter` is one a sweep can boot on; warns when it is not
        def adapter_known?(adapter)
          return true if ADAPTERS.include?(adapter)

          warn "unknown --adapter #{adapter} — memory, sqlite, or postgres"
          false
        end

        # @return [Boolean] whether the chosen adapter can be used: only `postgres` needs a server
        def adapter_ready?(options)
          options[:adapter] != :postgres || postgres_reachable?
        end

        # One child per core; a real Postgres runs one at a time.
        #
        # @return [Integer] how many children may run at once
        def worker_count(options)
          options[:workers] || (options[:adapter] == :postgres ? 1 : Etc.nprocessors)
        end

        # `postgres` needs a reachable local server and is slower per dispatch, so pass smaller
        # `--seeds` and `--steps`.
        #
        # @return [Boolean] whether a local Postgres answers; warns why when it does not
        def postgres_reachable?
          require "pg"
          PG.connect(dbname: "postgres").close
          true
        rescue LoadError, PG::Error => e
          warn "--adapter postgres needs a reachable local Postgres — #{e.class}: #{e.message}"
          false
        end
      end
    end
  end
end
