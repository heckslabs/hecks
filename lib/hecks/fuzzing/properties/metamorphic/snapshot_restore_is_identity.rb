# frozen_string_literal: true

module Hecks
  module Fuzzing
    module Properties
      module Metamorphic
        # `snapshot` then `restore` is the identity: a snapshot taken after the first half of the
        # steps, restored after the second half, gives back the instances read at the snapshot.
        # A session holds one snapshot (`cli.rs`), so the property takes exactly one.
        module SnapshotRestoreIsIdentity
          module_function

          # Plays half the steps, snapshots, plays the rest and restores.
          #
          # @param probe [Probe] a greeted serve connection
          # @param steps [Array<Hash>] playable steps
          # @return [true, String] true, or that the restore did not give the snapshot back
          def call(probe, steps)
            rest = steps.drop(steps.size / 2)
            probe.session do |name|
              probe.play(name, steps.first(steps.size / 2))
              taken = probe.instances(name)
              probe.play(name, [{ "snapshot" => true }, *rest, { "restore" => true }])
              probe.instances(name) == taken || "restore after #{rest.size} steps did not give the snapshot back"
            end
          end
        end
      end
    end
  end
end
