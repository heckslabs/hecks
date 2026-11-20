# frozen_string_literal: true

require "securerandom"
require_relative "../started_work"
require_relative "breaker_door"
require_relative "reap_door"
require_relative "own_cascade"
require_relative "posted_beat"
require "hecks/signalbox/adapters/pressure_signal"

module Hecks
  module Adapters
    class Dispatching
      # Delegate's one handle on Signalbox for admission: a Signalbox booted standing alone from
      # its directory, in Memory, once per process. It begins one pressure beat (Signalbox's own
      # `Looking` port reads the machine, and its policies set the headroom and the band) and asks
      # `Admission.Admit` by dry run, so nothing is kept and Roundhouse starts nothing from it. For
      # protection it reads the breakers' order and trips one by dry run ({BreakerDoor}); for
      # reaping it asks clearance and rules each subject by dry run ({ReapDoor}).
      #
      # Its runtime is a registry of its own, so each dispatch into it begins its own cascade
      # ({OwnCascade}) whatever reaction the caller is in. A beat is cleared when it published a
      # `Pressure` record; one that was not (a beat from a linked worktree or the train copy)
      # answers from the posted signal instead ({PostedBeat}).
      class SignalboxDoor
        include BreakerDoor
        include ReapDoor
        include PostedBeat

        # Where the Signalbox bluebook stands.
        HOME = File.expand_path("../../../signalbox", __dir__)

        # The head of a refused admission's message, before the given that refused it.
        REFUSED = /\AAdmit refused — /

        # @return [SignalboxDoor] the process's one door, booted on first use
        def self.shared = @shared ||= new

        # @param runtime [#dispatch, #dry_run?, #registry, nil] a booted Signalbox; booted from
        #   the Signalbox directory when nil
        # @param signal [#call] answers the posted signal while it is current, else nil; the
        #   {PressureSignal} file when absent. Admission has its own switch, so the door reads it
        #   whether or not the `signalbox_pressure` switch has the other readers read it.
        def initialize(runtime = nil, signal: -> { PressureSignal.current })
          @runtime = runtime && OwnCascade::Runtime.new(runtime)
          @signal = signal
        end

        # @return [Hash] the beat's `headroom`, the world's marks and draws, and the `band` its
        #   Pressure stands in; the posted signal's band, headroom and age when the beat was not
        #   cleared; the dark band when neither holds a current reading
        def look
          key = "admission-#{SecureRandom.hex(6)}"
          runtime.dispatch("Signalbox::Beat.Begin", with: { beat: { value: key } })
          beat = record("Beat", key)
          pressure = record("Pressure", key)
          pressure ? { band: value(pressure, :band), **beat_facts(beat) } : posted(beat)
        end

        # @param facts [Hash] the `Admission.Admit` arguments, each as `{ value: }`
        # @return [String, nil] the given that refuses the admission, nil when it is admitted
        def refusal(facts)
          runtime.dry_run?("Signalbox::Admission.Admit", **facts)
          nil
        rescue StandardError => e
          e.message.sub(REFUSED, "")
        end

        # @param verb [String] a Signalbox world verb, such as `ramp` or `fuses`
        # @return [Hash{Symbol => Object}] what the world declares for it, empty when nothing
        def setting(verb)
          found = runtime.registry.world("Signalbox")&.for_verb(verb)
          found.is_a?(Hash) ? found.transform_keys(&:to_sym) : {}
        rescue StandardError
          {}
        end

        private

        def runtime = @runtime ||= OwnCascade::Runtime.new(Hecks.boot(HOME, install_driving: false))

        def beat_facts(beat)
          return { headroom: 0, floor: 0, gap: 0, age: 0, stale_after: 0, draw: 0 } unless beat

          { headroom: value(beat, :headroom), floor: value(beat, :floor), gap: value(beat, :gap),
            age: value(beat, :age), stale_after: value(beat, :stale_after), draw: value(beat, :coder_draw) }
        end

        def record(name, key)
          aggregate = runtime.bluebook("Signalbox").aggregates.find { |held| held.hecks_name == name }
          aggregate && runtime.registry.repository("Signalbox", aggregate).find(key)
        end

        def value(record, field) = StartedWork.value(record, field)
      end
    end
  end
end
