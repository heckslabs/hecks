module Hecks
  module Adapters
    module Driving
      module CliRunner
        # Answers a creating command that names a run key the store already holds.
        #
        # Where the aggregate persists (SQLite, Postgres), a repeat with the same key and the same
        # arguments answers the record written first, and a repeat with other arguments is refused:
        # the key names a different run. Memory holds nothing across processes, so it cannot
        # answer a repeat; it refuses the key and says which store would answer it.
        module RunReplay
          MEMORY = "Memory".freeze

          module_function

          # @param runtime [Runtime::Dispatcher] the booted domain
          # @param spec [Hash] the command's projected spec
          # @param args [Hash] the parsed arguments, including `run` when one was given
          # @return [Array(String, Integer), nil] the answer and its status, or nil when the
          #   key is not recorded and the command should run
          def answer(runtime, spec, args)
            return unless replayable?(runtime, spec, args)

            target = target(runtime, spec)
            record = target && recorded(target, run_key(args))
            return unless record

            return memory_refusal(args) if memory?(target)

            same?(record, args) ? [recorded_text(record, args), ExitStatus::ANSWERED] : [different_text(args), ExitStatus::REFUSED]
          end

          # Whether the command creates a record under a run key the caller gave.
          def replayable?(runtime, spec, args)
            spec[:creates] && args.key?(:run) && runtime.respond_to?(:registry)
          end

          # The registry, domain and aggregate the command writes to, or nil when it has none.
          def target(runtime, spec)
            registry = runtime.registry
            domain = registry.first_domain_name
            aggregate = registry.bluebook(domain)&.aggregate(spec[:group].to_s)
            aggregate && { registry: registry, domain: domain, aggregate: aggregate }
          end

          # Whether the aggregate's authoritative store is Memory.
          def memory?(target)
            bind = Ports::Persistence::BindingPolicy.resolve(target[:registry], target[:domain], target[:aggregate])
            bind.adapter.to_s == MEMORY
          end

          # The run key's value, whether given bare or as `{ value: }`.
          def run_key(args)
            value = args[:run]
            value.is_a?(Hash) ? value[:value] : value
          end

          # The stored record of the key, or nil when none is held.
          def recorded(target, key)
            registry, domain = target.values_at(:registry, :domain)
            registry.repository(domain, target[:aggregate]).find(key.to_s)
          end

          # Whether the stored record holds every argument the repeat gave.
          def same?(record, args)
            given(args).all? { |name, value| stored(record, name) == value.to_s }
          end

          # A stored field as its text: a value object answers its `value` field.
          def stored(record, name)
            held = record.state[name.to_sym]
            (held.is_a?(Hecks::Runtime::Value) ? held[:value] : held).to_s
          end

          # The arguments that describe the record, without the run key.
          def given(args)
            args.except(:run).transform_values { |value| plain(value) }
          end

          # A value as its text: `{ value: x }` and `{ cents: x }` both answer `x`.
          def plain(value)
            return value unless value.is_a?(Hash)

            value.values.first
          end

          # The first answer's text: the run key, the record it already holds and the ids it named.
          def recorded_text(record, args)
            JSON.pretty_generate("id" => run_key(args).to_s, "state" => recorded_state(record), "events" => [],
                                 "ids" => { "run" => run_key(args).to_s, "id" => record.id.to_s })
          end

          # The stored fields as text, keyed by name, then the record's id, as the first answer
          # printed them.
          def recorded_state(record)
            fields = record.state.keys.to_h { |name| [name.to_s, stored(record, name)] }
            fields.merge("id" => record.id.to_s)
          end

          # The refusal for a key held with other arguments.
          def different_text(args)
            "[already_recorded] refused: run #{run_key(args)} is already recorded with other arguments: nothing written"
          end

          # The refusal for a key held in Memory, which does not remember runs across processes.
          def memory_refusal(args) = [refusal_text(args), ExitStatus::REFUSED]

          # The text naming Memory and the persisting stores that would answer the repeat.
          def refusal_text(args)
            "[memory_store] refused: run #{run_key(args)} is held in Memory, which does not remember runs across " \
              "processes: nothing written. A persisting store (SQLite or Postgres) answers a repeat " \
              "with the first outcome."
          end
        end
      end
    end
  end
end
