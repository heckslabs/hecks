# frozen_string_literal: true

require "json"
require_relative "protocol"
require_relative "rows"

module Hecks
  module QualityControlCli
    class QaRoundTrip
      # Plays protocol steps against a Hecks domain and answers what the protocol says an
      # implementation prints: a line per step, then the final state. It is how the benchmark's
      # reference answers are made from the original domain, and how a recovered domain is scored.
      class Player
        # @param domain_path [String] a domain directory `Hecks.boot` can boot
        # @param verb_map [Hash{String => String}] protocol commands to play as another command of
        #   this domain, for a recovered domain that reached one through an entry point of its own
        def initialize(domain_path, verb_map: {})
          @runtime = Hecks.boot(domain_path, environment: nil)
          @domain = @runtime.registry.bluebooks.keys.first.to_s
          @chapter = @runtime.registry.bluebook(@domain)
          @ir = @chapter.to_h
          @verb_map = verb_map
        end

        # Plays a script from a fresh boot's state onward.
        #
        # @param steps [Array<Hash>] protocol steps, as `Protocol#step` writes them
        # @return [Array<Hash>] one `"step"` line per step, then one `"state"` line
        def play(steps)
          lines = steps.each_with_index.map { |step, index| { "step" => index }.merge(outcome(step)) }
          lines << { "state" => state }
        end

        private

        def outcome(step) = step["query"] ? query(step) : command(step)

        # A refused command changes nothing and emits nothing; what refused it is not compared.
        def command(step)
          path = @verb_map.fetch(step["command"], step["command"])
          before = @runtime.events.to_a.size
          to, facts = envelope(path, step["args"] || {})
          verb = qualified(path)
          to.nil? ? @runtime.dispatch(verb, with: facts) : @runtime.dispatch(verb, to: to, with: facts)
          { "ok" => true, "events" => event_names(before) }
        rescue StandardError
          { "ok" => false, "events" => [] }
        end

        def query(step)
          rows = @runtime.query(qualified(step["query"]), **(step["args"] || {}).transform_keys(&:to_sym))
          { "ok" => true, "rows" => Array(rows).map { |row| Rows.plain(row.to_h).except("id") } }
        rescue StandardError
          { "ok" => false, "rows" => [] }
        end

        def qualified(path)
          *owners, verb = path.split(".")
          "#{@domain}::#{owners.join("::")}.#{verb}"
        end

        def event_names(from)
          @runtime.events.to_a.drop(from).map { |event| event.name.to_s.split(/::|\./).last }
        end

        # Splits a step's args into the record a command addresses (`to:`) and its facts.
        def envelope(path, args)
          aggregate_name, *rest = path.split(".")
          aggregate = aggregate_ir(aggregate_name)
          key = Protocol.reference_key(aggregate_name)
          return entity_envelope(aggregate, rest.first, args, key) if rest.size == 2
          return [nil, args] unless acts_on_itself?(aggregate, rest.first)

          [args[key], args.except(key)]
        end

        def entity_envelope(aggregate, entity_name, args, key)
          entity = aggregate[:entities].find { |candidate| candidate[:name] == entity_name }
          head = entity[:identified_by].first.split(".").first
          [{ aggregate: args[key], entities: [args[head]] }, args.except(key, head)]
        end

        def acts_on_itself?(aggregate, command_name)
          aggregate[:commands].any? { |command| command[:name] == command_name && command[:references] == aggregate[:name] }
        end

        def aggregate_ir(name) = @ir[:aggregates].find { |aggregate| aggregate[:name] == name } || {}

        def state
          @chapter.aggregates.to_h do |aggregate|
            records = repository_records(aggregate).map { |record| Rows.sorted_entities(Rows.plain(record), @ir) }
            [aggregate.hecks_name, records.sort_by { |record| JSON.generate(record) }]
          end
        end

        def repository_records(aggregate)
          repository = @runtime.registry.repository(@domain, aggregate)
          list = repository.respond_to?(:all) ? repository.all : repository.each.to_a
          list.map { |record| record.respond_to?(:state) ? record.state : record.to_h }
        end
      end
    end
  end
end
