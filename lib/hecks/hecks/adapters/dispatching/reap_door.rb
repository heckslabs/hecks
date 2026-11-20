# frozen_string_literal: true

require "securerandom"

module Hecks
  module Adapters
    class Dispatching
      # What {SignalboxDoor} asks of Signalbox for a reap (ADR 0222, phase 3, reaping): whether
      # this copy is cleared to act, and Signalbox's ruling on one subject, both without keeping
      # anything. Clearance comes from one pressure beat, so the view, its age and its staleness
      # bound are read through Signalbox's own `Looking` port and world.
      #
      # It needs the including door's `runtime`, `record` and `value`.
      module ReapDoor
        # The head of a refused command's message, before the given that refused it.
        REFUSAL = /\A\w+ refused — /

        # @return [String, nil] why this copy may not reap, nil when Signalbox clears it
        def reap_clearance
          key = "reap-#{SecureRandom.hex(6)}"
          runtime.dispatch("Signalbox::Beat.Begin", with: { beat: { value: key } })
          return nil if record("Clearance", key)

          beat = record("Beat", key)
          return "the beat could not look at the machine" unless beat && value(beat, :head)

          grant_refusal(key, beat) || "the beat's view was not cleared"
        end

        # @param facts [Hash{Symbol => Object}] the `Reaping.Rule` arguments, as plain values
        # @return [String, nil] the given that refuses the reap, nil when Signalbox rules it reaped
        def reap_refusal(facts) = dry_refusal("Signalbox::Reaping.Rule", facts)

        private

        def grant_refusal(key, beat)
          facts = %i[head main missing age stale_after].to_h { |field| [field, value(beat, field)] }
          dry_refusal("Signalbox::Clearance.Grant", { clearance: "#{key}:reaper", part: "reaper", **facts })
        end

        def dry_refusal(command, facts)
          runtime.dry_run?(command, **facts.transform_values { |fact| { value: fact } })
          nil
        rescue StandardError => e
          e.message.sub(REFUSAL, "")
        end
      end
    end
  end
end
