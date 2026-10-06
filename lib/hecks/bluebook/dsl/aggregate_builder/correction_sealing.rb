module Hecks
  module Bluebook
    module DSL
      class AggregateBuilder
        # Build-time checks of `corrects`: the corrected event must be one this aggregate emits,
        # and a derived reversal must be statically invertible. Included into AggregateBuilder
        # through `Sealing`.
        module CorrectionSealing
          # The mutation op that undoes each op a `corrects ... reverses: true` can derive from.
          INVERSE_OP = { increment: :decrement, decrement: :increment }.freeze

          private

          # Checks `corrects` once every sibling command is known: the named event must be emitted
          # by a command on this aggregate, and `reverses: true` needs every source mutation to be
          # an increment/decrement, the only ops invertible without runtime data.
          def seal_correction_targets
            emitted_by = commands_by_emitted_event

            @commands.each do |command|
              correction = command.mutations.find { |mutation| mutation.op == :corrects }
              seal_correction(command, correction, emitted_by[correction.target]) if correction
            end
          end

          def commands_by_emitted_event
            emitted_by = Hash.new { |hash, key| hash[key] = [] }
            @commands.each { |command| command.emits.each { |event_name| emitted_by[event_name] << command } }
            emitted_by
          end

          def seal_correction(command, correction, sources)
            event = correction.target
            refuse_unemitted_correction!(command, event) if sources.empty?
            return unless correction.source[:reverses]

            refuse_reversal_with_own_sets!(command, event)
            derived = sources.flat_map(&:mutations).reject { |mutation| mutation.op == :corrects }
            refuse_uninvertible_sources!(command, event, derived)
            derived.each { |mutation| command.mutations << inverse_of(mutation) }
          end

          def inverse_of(mutation)
            Mutation.new(target: mutation.target, op: INVERSE_OP.fetch(mutation.op), source: mutation.source)
          end

          def refuse_unemitted_correction!(command, event)
            raise Malformed,
                  "#{@name}.#{command.hecks_name} corrects #{event.inspect}, but nothing " \
                  "declared on #{@name} ever emits it — corrects names a fact this " \
                  "aggregate actually announces, not an aspiration"
          end

          def refuse_reversal_with_own_sets!(command, event)
            return unless command.mutations.any? { |mutation| mutation.op != :corrects }

            raise Malformed,
                  "#{@name}.#{command.hecks_name} declares both corrects #{event.inspect}, " \
                  "reverses: true AND its own sets — reverses: true means the correction " \
                  "is DERIVED; write one or the other, never both"
          end

          def refuse_uninvertible_sources!(command, event, derived)
            unsupported = derived.reject { |mutation| INVERSE_OP.key?(mutation.op) }
            return if unsupported.empty?

            raise Malformed,
                  "#{@name}.#{command.hecks_name} corrects #{event.inspect}, reverses: " \
                  "true, but the command(s) that emit it use " \
                  "#{unsupported.map(&:op).uniq.join(", ")} — not statically invertible " \
                  "(set needs the specific prior value, multiply/clamp are lossy) — " \
                  "declare the corrective sets by hand instead"
          end
        end
      end
    end
  end
end
