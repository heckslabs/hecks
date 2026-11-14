require_relative "../errors"
require_relative "../reaction_notice"

module Hecks
  module Runtime
    module Outbox
      # What the relay does when another process holds the store past the wait while a row is
      # claimed, run or settled. A row is drained after the command that enqueued it has saved,
      # so a held store here is the reaction's trouble and is never raised to that command.
      #
      # A row the store would not let be claimed stays pending. A row whose reaction wrote
      # nothing is put back to pending. Either is run by the next boot over the same store
      # (`Redrive#redrive!`); a process that stays up does not look again. Mixed into {Relay},
      # which supplies `log`.
      module HeldStore
        # Raised by the consumer runner when the reaction found the store held before it wrote.
        class Unwritten < StandardError; end

        # How many times a row is put back to pending before it is left claimed. Each try waits
        # the store's own busy timeout.
        PUT_BACK_TRIES = 2

        private

        # Claims the row, or leaves it pending when the store is held.
        def claim(row, repository)
          repository.outbox_claim(row.id)
        rescue StoreBusy => e
          note_held(row, e, pending: true)
          false
        end

        # Records an outcome on the row, or leaves the row claimed when the store is held: its
        # reaction has run, so the boot that finds the claim stalled does not run it again.
        def settle(row, repository, status, error = nil)
          repository.outbox_settle(row.id, status: status, error: error)
          row.status = status
          row.error  = error
        rescue StoreBusy => e
          note_held(row, e, pending: false, ran: true)
        end

        # Puts a claimed row whose reaction wrote nothing back to pending. When the store stays
        # held for every try the row is left claimed and named with the way to run it by hand.
        def put_back(row, repository, error)
          PUT_BACK_TRIES.times do
            repository.outbox_settle(row.id, status: "pending")
            row.status = "pending"
            return note_held(row, error, pending: true)
          rescue StoreBusy
            next
          end
          note_held(row, error, pending: false, ran: false)
        end

        def note_held(row, error, pending:, ran: nil)
          @log << { outbox: row.delivery_id, consumer: row.consumer, delivered: false, held: true,
                    pending: pending, reason: error.message }
          ReactionNotice.say "[hecks] outbox row #{row.delivery_id} (#{row.consumer} on #{row.event[:name]}): " \
                             "the store was busy (#{error.message}). #{held_fate(pending, ran)}"
        end

        def held_fate(pending, ran)
          return "It is pending and the next boot over this store runs it." if pending
          return "Its reaction ran; the row stays claimed and is not run again." if ran

          "Its reaction wrote nothing and the row could not be put back, so it stays claimed and no boot " \
            "runs it: redrive it by this delivery id (Operation.RedriveOutbox, row)."
        end
      end
    end
  end
end
