require_relative "../instance"

module Hecks
  module Runtime
    class CommandInterpreter
      # Lets a creating command take the id of an occupant whose lifecycle has ended: hydration
      # decides and remembers the occupant, the save step archives it as `<id>~<n>` first.
      module OccupantReuse
        private

        # Refuses an occupied id unless the occupant has ended, in which case it is remembered
        # on the context for the save step to archive.
        def claim_creation_id(ctx, id, occupant)
          ctx.archiving = nil
          return unless occupant

          raise_already_exists(ctx.command, ctx.aggregate, id) unless reusable_occupant?(ctx.aggregate, occupant)

          ctx.archiving = occupant
        end

        # Whether the occupant's lifecycle status is marked reusable, or is no declared state.
        # A record with no status, or an aggregate with no lifecycle, is never reusable.
        def reusable_occupant?(aggregate, occupant)
          lifecycle = aggregate.lifecycle
          status    = lifecycle && occupant[lifecycle.field]
          return false if status.nil?

          (lifecycle.marked(:reusable) || []).include?(status.to_s) || !lifecycle.states.include?(status.to_s)
        end

        # Saves the remembered occupant, fields kept, under the first free `<id>~<n>`.
        def archive_occupant(ctx)
          occupant = ctx.archiving
          return unless occupant

          archived_id = free_archive_id(ctx.repository, occupant.id)
          ctx.repository.save(Instance.new(aggregate: ctx.aggregate, id: archived_id, state: occupant.state.dup,
                                           hydrate: false))
        end

        def free_archive_id(repository, id)
          (1..).each do |n|
            candidate = "#{id}~#{n}"
            return candidate unless repository.find(candidate)
          end
        end
      end
    end
  end
end
