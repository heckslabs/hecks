module Hecks
  module Adapters
    module Driving
      module Resident
        module Trace
          # The phases a write passes through after its boot, named on the same timeline as the
          # launcher's marks:
          #
          #     store_open, event_recorded, reactions_begin/_end, slot_wait_begin/_end
          #
          # `event_recorded` is the moment the save has committed and the reactions it owes are
          # about to run; it is not the time of the save itself.
          module Marks
            # Names the reactions a committed write owes, once for the write: a read announces
            # nothing, and a reaction that dispatches again is inside the first one's marks.
            module Reactions
              DEPTH = :hecks_trace_reactions

              # Marks the reactions around the block, and clears the nesting flag however it ends.
              #
              # @yieldreturn [Object] the reactions' result
              # @return [Object] what the block returned
              def self.around
                Trace.mark("event_recorded")
                Trace.mark("reactions_begin")
                Thread.current[DEPTH] = true
                yield
              ensure
                Thread.current[DEPTH] = nil
                Trace.mark("reactions_end")
              end

              private

              def react(announced, *, **)
                return super if announced.empty? || Thread.current[DEPTH]

                Reactions.around { super }
              end
            end

            # Names each store a line opens.
            module StoreOpen
              def initialize(...)
                super.tap { Trace.mark("store_open") }
              end
            end

            # Names the wait for a heavy-job place, which ends when a place is taken.
            module HeavySlot
              private

              def acquire(*, **)
                Trace.mark("slot_wait_begin")
                super.tap { Trace.mark("slot_wait_end") }
              end
            end

            module_function

            # Puts each wrapper on what it names, loading what a traced line has not yet.
            #
            # @return [Array<Symbol>] the hooks attached
            def attach
              require "sqlite3"
              require "hecks/hecks/adapters/codebase/heavy_slots"
              Hecks::Runtime::Dispatcher.prepend(Reactions)
              ::SQLite3::Database.prepend(StoreOpen)
              Hecks::Adapters::Codebase::HeavySlots.prepend(HeavySlot)
              %i[reactions store_open heavy_slot]
            end
          end
        end
      end
    end
  end
end
