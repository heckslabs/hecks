module Hecks
  module Fuzzing
    module Replay
      # Replays a step's guard read-only, before the real dispatch can mutate anything, so the
      # outcome can be compared with what the dispatch actually did.
      module GuardCheck
        # The command a guard check is about, and where it lives.
        Target = Struct.new(:domain, :aggregate_name, :command_name, :aggregate, :command)

        module_function

        # Resolves the record (if any) this step's guard should be checked against, and
        # replays enforce_givens then admissible_transition, in that order, to mirror
        # the real DISPATCH_ORDER. `nil` for anything out of scope.
        def build(runtime, verb, args)
          target = target_for(runtime, verb)
          return nil unless target

          id = Replay.identity_for(target.aggregate, target.command, args)
          record = id && runtime.registry.repository(target.domain, target.aggregate).find(id)
          return nil unless record

          { verb: verb, domain: target.domain, aggregate: target.aggregate_name, command: target.command_name,
            id: id, **recomputation(runtime, target, record, args) }
        rescue StandardError
          nil
        end

        # The aggregate-level command `verb` names, when it has a guard worth checking.
        def target_for(runtime, verb)
          domain_name, aggregate_name, command_name = Naming.split_verb(verb)
          return nil unless command_name && !command_name.include?(".")

          aggregate = runtime.registry.bluebook(domain_name)&.aggregate(aggregate_name)
          command   = aggregate&.command(command_name)
          return nil unless checkable?(aggregate, command)

          Target.new(domain_name, aggregate_name, command_name, aggregate, command)
        end

        def checkable?(aggregate, command)
          aggregate && command && !command.creates? && guarded?(aggregate, command)
        end

        # A transition-only guard (no per-command `from:`/`given`, only an aggregate
        # `lifecycle` block naming this command) still counts as something to check,
        # now that `admissible_transition` is reproduced.
        def guarded?(aggregate, command)
          has_transition = aggregate.lifecycle&.transitions_for(command.hecks_name)&.any?
          !(command.givens.empty? && !command.from && !has_transition)
        end

        # What an independent run of the guard says about the step.
        #
        # Real dispatch normalizes args (step_normalize_args) before it ever reaches
        # enforce_givens, coercing a bare scalar like "white" into its command's declared
        # value-object shape. Skipping that here would hand enforce_givens the raw fuzzed
        # shape instead, and a `given` comparing a normalized field against it would walk a
        # path a String happens to answer (a substring lookup) rather than the refusal real
        # dispatch raises. `send` reaches the interpreter's own private coercion (the same
        # idiom SelfConsistency#last_advancing_event uses for `saga_correlation`) rather than
        # reimplementing it here.
        def recomputation(runtime, target, record, args)
          rules = Runtime::CommandRules.new(runtime.registry)
          interpreter = Runtime::CommandInterpreter.new(runtime.registry, rules: rules)
          normalized_args = interpreter.send(:normalize_args, target.aggregate, target.command, args)
          kind = refusal_class_name(rules, target, record, normalized_args)
          { recomputed_refused: !kind.nil?, recomputed_kind: kind }
        end

        # The class name of the guard refusal the independent run raises, or nil when it admits.
        def refusal_class_name(rules, target, record, normalized_args)
          rules.enforce_givens(record.dup, target.command, normalized_args, domain: target.domain, declaring: target.aggregate)

          # A second, separate DISPATCH_ORDER step: the aggregate's own `lifecycle`
          # transition guard is a wholly different method from enforce_givens' own
          # per-command `from:` check, called only when enforce_givens didn't already refuse.
          # It reads only the record's own lifecycle field and the command's declared
          # transitions, never `args`, so it needs no normalized input of its own.
          rules.admissible_transition(target.aggregate, target.command, record.dup)
          nil
        rescue *GUARD_REFUSAL_CLASSES => e
          e.class.name
        end
      end
    end
  end
end
