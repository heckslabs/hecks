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
        # @param delivery_id [String] the row's `delivery_id`, as the stalled-row warning names it
        # @return [Array<Row>] the row when it redrove, `[]` when its consumer failed again
        # @raise [Hecks::Runtime::NotFound] when no claimed row has that delivery id
        def redrive_row!(delivery_id)
          stores.each do |repository|
            row = repository.outbox_rows(status: "claimed").find { |candidate| candidate.delivery_id == delivery_id }
            return (redrive_claimed?(row, repository, true) ? [row] : []) if row
          end
          raise Hecks::Runtime::NotFound, "no claimed outbox row #{delivery_id.inspect}"
        end

        # Settles the one claimed row named by its delivery id as failed, without running its
        # consumer: for a row whose effect is known to have landed, or that nobody wants run, so
        # the stalled-row warning stops naming it. The error says it was abandoned by hand.
        #
        # @param delivery_id [String] the row's `delivery_id`, as the stalled-row warning names it
        # @return [Array<Row>] the row that was settled
        # @raise [Hecks::Runtime::NotFound] when no claimed row has that delivery id
        def abandon_row!(delivery_id)
          stores.each do |repository|
            row = repository.outbox_rows(status: "claimed").find { |candidate| candidate.delivery_id == delivery_id }
            return [abandon(row, repository)] if row
          end
          raise Hecks::Runtime::NotFound, "no claimed outbox row #{delivery_id.inspect}"
        end

        private

        def abandon(row, repository)
          repository.outbox_settle(row.id, status: "failed", error: "abandoned by an operator, not redelivered")
          row.status = "failed"
          row
        end

        # The rows of one store that redrove: its pending rows first, then its claimed ones.
        def redrive_store(repository, claimed)
          redriven = repository.outbox_rows(status: "pending").select { |row| deliver_row(row, repository) }
          redriven + repository.outbox_rows(status: "claimed").select { |row| redrive_claimed?(row, repository, claimed) }
        end

        def redrive_claimed?(row, repository, claimed)
          unless claimed
            warn_stalled(row)
            return false
          end

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
