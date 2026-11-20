# frozen_string_literal: true

module Hecks
  module Fuzzing
    module Properties
      module Metamorphic
        # Replaying the journal is the identity: the verb steps a session accepted, replayed into a
        # fresh session with the ids each one consumed, give the same instances. The refused steps
        # and the dry runs carry nothing a replay needs.
        module JournalReplayIsIdentity
          module_function

          # Plays the steps, then replays the accepted ones into a second session.
          #
          # @param probe [Probe] a greeted serve connection
          # @param steps [Array<Hash>] playable steps
          # @return [true, String] true, or that the replay did not reproduce the store
          def call(probe, steps)
            accepted, original = journal(probe, steps)
            replayed = probe.session(ids: accepted.flat_map(&:ids)) do |name|
              probe.play(name, accepted.map(&:message))
              probe.instances(name)
            end
            replayed == original || "replaying the #{accepted.size} accepted steps gave a different store"
          end

          # @return [Array(Array<Probe::Played>, Hash)] the accepted verb steps and the final store
          def journal(probe, steps)
            probe.session do |name|
              [probe.play(name, steps).select { |played| played.ok? && played.verb? }, probe.instances(name)]
            end
          end
        end
      end
    end
  end
end
