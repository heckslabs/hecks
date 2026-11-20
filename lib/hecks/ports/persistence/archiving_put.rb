require_relative "replace_when"

module Hecks
  module Ports
    module Persistence
      # The atomic put an adapter runs inside its own critical section: refuse a live occupant,
      # archive an ended one under `<id>~<n>` with its fields kept, then write the entry. An
      # adapter supplies `occupied?(id)`, `find(id)` and `append`/`project`, and overrides
      # `write_put` when it journals and projects in one step.
      module ArchivingPut
        private

        # Decides the put against the occupant and writes it.
        #
        # @param entry [Entry] the save to store
        # @param insert_only [Boolean] true to refuse an occupant the rule does not replace
        # @param replace_when [ReplaceWhen, nil] when an occupant has ended; nil archives nothing
        # @return [Symbol] `:inserted`, `:replaced`, or `:conflicted` when nothing was written
        def archiving_put(entry, insert_only, replace_when)
          occupant = occupant_for(entry.id, replace_when)
          ended = ended?(occupant, replace_when)
          return :conflicted if insert_only && occupant && !ended

          archive_occupant(entry.id, occupant, replace_when) if ended
          write_put(entry)
          occupant ? :replaced : :inserted
        end

        # Whether an occupant is there and the rule frees its id; never without a rule.
        def ended?(occupant, replace_when)
          return false unless occupant && replace_when

          replace_when.replaces?(occupant)
        end

        # The occupant itself when the rule must judge it; otherwise only whether one is there.
        def occupant_for(id, replace_when)
          return find(id) if replace_when

          occupied?(id) || nil
        end

        def archive_occupant(id, occupant, replace_when)
          archive_id = replace_when.archive_id(id) { |candidate| occupied?(candidate) }
          write_put(Entry.new(operation: "save", id: archive_id, state: occupant.state.dup))
        end

        def write_put(entry)
          append(entry)
          project(entry)
        end
      end
    end
  end
end
