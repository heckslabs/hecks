# frozen_string_literal: true

require "etc"
require_relative "../../tools"

module Hecks
  module Tools
    module FuzzSweep
      # The command line of a sweep: its options, and what the chosen adapter needs.
      module Options
        # The options that take a whole number, and the key each fills.
        INTEGER_OPTIONS = { "--seeds" => :seeds, "--steps" => :steps, "--workers" => :workers,
                            "--list-shards" => :list_shards }.freeze

        # The most children a Postgres sweep runs at once unless `--workers` says otherwise.
        POSTGRES_WORKERS = 4

        # @param args [Array<String>] the command line, consumed
        # @return [Hash, nil] `seeds`, `steps`, `workers`, `adapter`, `persist`, `domain`, `shard`
        #   (the shard's number and the shard count) and `list_shards` (how many shards to list);
        #   nil after a refusal
        def parse(args)
          options = { seeds: 20, steps: 30, workers: nil, adapter: :memory, domain: nil, persist: false,
                      shard: nil, list_shards: nil }
          until args.empty?
            apply_option(options, args.shift, args)
            return nil unless adapter_known?(options[:adapter])
          end
          settle_shards(options)
        end

        # Records one command-line word in `options`, taking its value from `rest` when it has one.
        def apply_option(options, arg, rest)
          if (key = INTEGER_OPTIONS[arg]) then options[key] = Integer(rest.shift)
          elsif arg == "--persist-regressions" then options[:persist] = true
          elsif arg == "--adapter" then options[:adapter] = adapter_name(rest.shift)
          elsif arg == "--shard" then options[:shard] = rest.shift.to_s
          else options[:domain] = arg
          end
        end

        # Turns `--shard I/N` into the pair it names, and refuses the shard options that do not fit
        # together or with what they split.
        #
        # @param options [Hash] the options as typed
        # @return [Hash, nil] the options with `shard` parsed, or nil after a refusal
        def settle_shards(options)
          return options if options.values_at(:shard, :list_shards).none?
          return nil unless shard_choice_clear?(options)

          options[:shard] &&= Shards.parse_shard(options[:shard])
          options.values_at(:shard, :list_shards).any? ? options : nil
        end

        # @return [Boolean] whether the shard options name one split of the corpus; warns why not
        def shard_choice_clear?(options)
          reason = shard_conflict(options)
          warn reason if reason
          reason.nil?
        end

        # @return [String, nil] why the shard options cannot be used together, or nil when they can
        def shard_conflict(options)
          if options[:shard] && options[:list_shards]
            "--shard sweeps one shard and --list-shards lists them all; use one"
          elsif options[:domain]
            "shards split every domain of the checkout, so no domain can be named"
          elsif options[:list_shards] && !options[:list_shards].positive?
            "--list-shards takes a shard count of 1 or more"
          end
        end

        # @param word [String, nil] the word after `--adapter`
        # @return [Symbol] the adapter it names, lowercased
        def adapter_name(word) = word.to_s.downcase.to_sym

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

        # One child per core. A real Postgres is capped, because each child holds its own
        # connections and its own scratch schema, and runs one at a time on macOS, where libpq
        # segfaults when a forked child connects.
        #
        # @return [Integer] how many children may run at once
        def worker_count(options)
          options[:workers] || (options[:adapter] == :postgres ? postgres_workers : Etc.nprocessors)
        end

        # @return [Integer] the children a Postgres sweep runs at once by default
        def postgres_workers
          RUBY_PLATFORM.include?("darwin") ? 1 : [Etc.nprocessors, POSTGRES_WORKERS].min
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
