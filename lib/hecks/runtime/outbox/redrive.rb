require_relative "stalled_notice"

module Hecks
  module Runtime
    module Outbox
      # What the relay does with the rows a crash left behind: a pending row is always safe to
      # deliver again, a claimed one (claimed, then never settled) is settled as abandoned once it
      # stands past the claim bound, and redelivered only when the caller says its effect did not
      # run. Mixed into `Relay`, which supplies `registry`, `stores`, `deliver_row` and `log`.
      module Redrive
        include StalledNotice

        # `pending` rows are always safe to redrive (never claimed yet).
        # A `claimed` row past the claim bound was left by a process that is gone. Unless
        # `claimed: true` says its effect did not run, it is settled as failed (abandoned, not
        # redelivered: a maybe-already-run consumer could double its effect) and named once, so no
        # later boot names it again.
        def redrive!(claimed: false)
          stores.flat_map { |repository| redrive_store(repository, claimed) }
        end

        # Redrives the one claimed row named by its delivery id, on the caller's word that its
        # effect did not run. Every other claimed row stays as it is, and a pending row is not
        # touched.
        #
        # @param delivery_id [String] the row's `delivery_id`, or its uuid when one claimed row
        #   carries it
        # @return [Array<Row>] the row when it redrove, `[]` when its consumer failed again
        # @raise [Hecks::Runtime::NotFound] when no claimed row has that delivery id, or the row
        #   was claimed too recently to be stalled
        def redrive_row!(delivery_id)
          repository, row = stalled_row(delivery_id)
          redrive_claimed?(row, repository, true) ? [row] : []
        end

        # Settles the one claimed row named by its delivery id as failed, without running its
        # consumer: for a row whose effect is known to have landed, or that nobody wants run, so
        # the stalled-row warning stops naming it. The error says it was abandoned by hand.
        #
        # @param delivery_id [String] the row's `delivery_id`, or its uuid when one claimed row
        #   carries it
        # @param reason [String, nil] why the row is abandoned, kept on the settled row's error
        # @return [Array<Row>] the row that was settled
        # @raise [Hecks::Runtime::NotFound] when no claimed row has that delivery id, the uuid
        #   names several, or the row was claimed too recently to be stalled
        def abandon_row!(delivery_id, reason: nil)
          repository, row = stalled_row(delivery_id)
          [abandon(row, repository, reason)]
        end

        private

        # The store and the claimed row that `delivery_id` names, once the row has stood claimed
        # past `STALLED_AFTER`: a younger claim is a reaction running in another process. The id
        # is the full `delivery_id`, or its uuid (the part before the `/`) when one claimed row
        # carries it.
        def stalled_row(delivery_id)
          repository, row = named_claimed_row(delivery_id)
          raise Hecks::Runtime::NotFound, "no claimed outbox row #{delivery_id.inspect}" unless row
          raise Hecks::Runtime::NotFound, in_flight_wording(row) unless row.stalled?(claim_bound)

          [repository, row]
        end

        def named_claimed_row(delivery_id)
          pairs = stores.flat_map { |store| store.outbox_rows(status: "claimed").map { |row| [store, row] } }
          pairs.find { |_, row| row.delivery_id == delivery_id } || uuid_claimed_row(pairs, delivery_id)
        end

        def uuid_claimed_row(pairs, uuid)
          named = pairs.select { |_, row| row.delivery_id.split("/", 2).first == uuid }
          raise Hecks::Runtime::NotFound, ambiguous_wording(uuid, named) if named.size > 1

          named.first
        end

        def ambiguous_wording(delivery_id, pairs)
          "outbox row #{delivery_id.inspect} names #{pairs.size} claimed rows: " \
            "#{pairs.map { |_, row| row.delivery_id }.join(", ")}; pass the full delivery id"
        end

        def in_flight_wording(row)
          "outbox row #{row.delivery_id} is in flight, claimed #{row.claimed_seconds_ago}s ago; only a row " \
            "claimed over #{claim_bound}s ago is stalled"
        end

        def abandon(row, repository, reason, by: "an operator")
          error = ["abandoned by #{by}, not redelivered", reason].compact.join(": ")
          repository.outbox_settle(row.id, status: "failed", error: error)
          row.status = "failed"
          row.error = error
          row
        end

        # The rows of one store that redrove: its pending rows first, then its claimed ones.
        def redrive_store(repository, claimed)
          redriven = repository.outbox_rows(status: "pending").select { |row| redrive_pending?(row, repository) }
          stalled = repository.outbox_rows(status: "claimed").select { |row| row.stalled?(claim_bound) }
          redriven + stalled.select { |row| redrive_claimed?(row, repository, claimed) }
        end

        def redrive_pending?(row, repository) = !withheld?(row) && deliver_row(row, repository)

        def redrive_claimed?(row, repository, claimed)
          unless claimed
            abandon_stalled(row, repository)
            return false
          end
          return false if withheld?(row)

          repository.outbox_settle(row.id, status: "pending")
          row.status = "pending"
          deliver_row(row, repository)
        end
      end
    end
  end
end
