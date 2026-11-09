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
          lifecycle ? lifecycle.reusable?(occupant[lifecycle.field]) : false
        end

        # Whether a creating command reads the occupant before it saves. Under ATOMIC_PUT the
        # adapter refuses an occupied id itself, so only an aggregate that marks states
        # `:reusable` reads, to tell an ended occupant from a live one.
        def reads_occupant?(ctx)
          ctx.strategy != DependencyPlanning::ATOMIC_PUT || frees_ended_ids?(ctx.aggregate)
        end

        # Whether the aggregate's lifecycle marks any state `:reusable`.
        def frees_ended_ids?(aggregate)
          lifecycle = aggregate.lifecycle
          !lifecycle&.marked(:reusable).nil?
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
