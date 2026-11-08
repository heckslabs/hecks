module Hecks
  module Runtime
    module Outbox
      # What the relay does with the rows a crash left behind: a pending row is always safe to
      # deliver again, a claimed one (claimed, then never settled) is only surfaced until the
      # caller says its effect did not run. Mixed into `Relay`, which supplies `stores`,
      # `deliver_row` and `log`.
      module Redrive
        # `pending` rows are always safe to redrive (never claimed yet).
        # `claimed` rows are only surfaced — redelivering a maybe-already-run
        # consumer needs an explicit `claimed: true`.
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
          raise Hecks::Runtime::NotFound, in_flight_wording(row) unless row.stalled?

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
            "claimed over #{STALLED_AFTER}s ago is stalled"
        end

        def abandon(row, repository, reason)
          error = ["abandoned by an operator, not redelivered", reason].compact.join(": ")
          repository.outbox_settle(row.id, status: "failed", error: error)
          row.status = "failed"
          row.error = error
          row
        end

        # The rows of one store that redrove: its pending rows first, then its claimed ones.
        def redrive_store(repository, claimed)
          redriven = repository.outbox_rows(status: "pending").select { |row| redrive_pending?(row, repository) }
          stalled = repository.outbox_rows(status: "claimed").select(&:stalled?)
          redriven + stalled.select { |row| redrive_claimed?(row, repository, claimed) }
        end

        def redrive_pending?(row, repository) = !withheld?(row) && deliver_row(row, repository)

        def redrive_claimed?(row, repository, claimed)
          unless claimed
            warn_stalled(row)
            return false
          end
          return false if withheld?(row)

          repository.outbox_settle(row.id, status: "pending")
          row.status = "pending"
          deliver_row(row, repository)
        end

        def warn_stalled(row)
          warn stalled_wording(row)
          @log << { outbox: row.delivery_id, consumer: row.consumer, kind: row.kind, stalled: true,
                    event: row.event[:name], aggregate: row.event[:aggregate], id: row.event[:id] }
        end

        def stalled_wording(row)
          "[hecks] outbox row #{row.delivery_id} (#{row.consumer} on #{row.event[:name]} for " \
            "#{row.event[:aggregate]}##{row.event[:id]}) was claimed before the last crash/restart and never " \
            "settled — its #{row.kind} may or may not have actually run. hecks does not auto-redrive a claimed " \
            "row (the outcome is unknown, and redelivering it could double the effect); inspect it and " \
            "redrive by hand with `runtime.outbox.redrive!(claimed: true)` once you know it is safe."
        end
      end
    end
  end
end
