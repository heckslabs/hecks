require_relative "../../bulk/sweep"
require_relative "../../runtime/errors"

module Hecks
  module Fuzzing
    module Properties
      # Property: a bulk run's per-row outcomes, and the records it leaves, equal dispatching each
      # row by hand (ADR 0121). Like `replay_is_deterministic` it boots twice itself, so it is not
      # in the battery `check` runs over one history.
      module BulkParity
        # One command sent over one query: a non-creating command addressed by a row of the
        # query's aggregate and needing no other argument, and a query that takes none.
        Pair = Struct.new(:verb, :over, :key, keyword_init: true) do
          # @return [String] how a finding names the pair
          def label = "#{verb} over #{over}"
        end

        # Replays `steps` twice. After the first, every pair is swept as a bulk run; after the
        # second, every row of every pair is dispatched by hand, in the order the query answers.
        # Each pair's outcomes and the records left after it must agree.
        #
        # @param domain_path [String] the domain directory
        # @param steps [Array<Hash>] a generated or recorded step list
        # @param adapter [Symbol] the persistence both boots are bound to
        # @return [true, String] true when they agree, or not applicable; otherwise the first pair
        #   whose outcomes or records differ
        def bulk_runs_match_hand_dispatch(domain_path, steps, adapter: :memory)
          return true unless BulkParity.attaches_bulk?(domain_path)

          swept   = BulkParity.played(domain_path, steps, adapter) { |runtime, pair| BulkParity.swept(runtime, pair) }
          by_hand = BulkParity.played(domain_path, steps, adapter) { |runtime, pair| BulkParity.by_hand(runtime, pair) }
          BulkParity.verdict(swept, by_hand)
        end

        module_function

        # Whether a hecksagon of the domain attaches the Bulk chapter: only such a domain can run
        # a bulk run, so only its seeds pay for the two extra boots.
        #
        # @param domain_path [String] the domain directory
        # @return [Boolean]
        def attaches_bulk?(domain_path)
          Dir.glob(File.join(domain_path, "**", "*.hecksagon")).any? { |path| File.read(path).include?('attaches "Bulk"') }
        end

        # Boots a copy, plays `steps`, then runs the block once per pair in order.
        #
        # @return [Array<Array>] per pair: its label, the block's outcomes, and the records after it
        def played(domain_path, steps, adapter)
          IsolatedBoot.call(domain_path, adapter: adapter) do |copy|
            runtime = Hecks.boot(copy, environment: nil)
            Replay::Session.new(runtime).play(steps)
            pairs(runtime).map { |pair| [pair.label, yield(runtime, pair), Replay.snapshot_instances(runtime)] }
          end
        end

        # The first pair the two runs disagree on, or true.
        def verdict(swept, by_hand)
          index = swept.each_index.find { |at| swept[at] != by_hand[at] }
          return true unless index

          label, outcomes, = swept[index]
          "#{label}: a bulk run answered #{outcomes.inspect}, dispatching each row by hand " \
            "#{by_hand[index][1].inspect}#{" and left different records" if outcomes == by_hand[index][1]}"
        end

        # Every pair the booted chapters declare, in declaration order.
        #
        # @param runtime [Runtime::Runtime] the booted domain
        # @return [Array<Pair>]
        def pairs(runtime)
          runtime.bluebooks.flat_map do |domain, bluebook|
            bluebook.aggregates.flat_map { |aggregate| aggregate_pairs("#{domain}::#{aggregate.hecks_name}", aggregate) }
          end
        end

        def aggregate_pairs(fqn, aggregate)
          queries = aggregate.queries.select { |query| query.attributes.empty? }
          aggregate.commands.reject(&:creates?).flat_map do |command|
            key = sole_key(command, aggregate)
            next [] unless key

            queries.map { |query| Pair.new(verb: "#{fqn}.#{command.hecks_name}", over: "#{fqn}.#{query.hecks_name}", key: key) }
          end
        end

        # The key a row of `aggregate` addresses `command` by, when it needs no other argument.
        def sole_key(command, aggregate)
          key = command.addressing_key_for(aggregate.hecks_name)
          key if key && command.attributes.all? { |attribute| attribute.optional? || attribute.name == key }
        end

        # The pair sent as a best_effort bulk run.
        def swept(runtime, pair)
          plan = Bulk::Plan.new(verb: pair.verb, over: pair.over, arguments: {}, mode: "best_effort")
          Bulk::Sweep.new(runtime.registry, plan).outcomes
        rescue StandardError => e
          [:crashed, e.class.name]
        end

        # The pair's rows read once, then each dispatched by hand: the oracle, sharing nothing
        # with the bulk run's row sweep.
        def by_hand(runtime, pair)
          runtime.query(pair.over).map { |row| hand_dispatch(runtime, pair, row[:id]) }
        rescue StandardError => e
          [:crashed, e.class.name]
        end

        def hand_dispatch(runtime, pair, id)
          runtime.dispatch_flat(pair.verb, pair.key => id)
          { row: id.to_s, delivered: true }
        rescue *Runtime::DOMAIN_REFUSALS => e
          { row: id.to_s, delivered: false, reason: e.message }
        end
      end
    end
  end
end
