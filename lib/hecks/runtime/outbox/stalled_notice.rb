module Hecks
  module Runtime
    module Outbox
      # How the relay deals with a claim a dead process left: the bound that makes a claim stale,
      # and the one warning and log finding that name a row as it is settled abandoned. Mixed into
      # `Redrive`, which supplies `abandon`, and through it `Relay`, which supplies `registry`
      # and `log`.
      module StalledNotice
        private

        # The seconds a claim may stand: the world's `outbox "Claims", stalled_minutes:` setting,
        # else `STALLED_AFTER`.
        def claim_bound
          setting = (registry.world("Hecks")&.settings || {})["outbox"]
          minutes = setting && Hecks::IndifferentKey.read(setting, :stalled_minutes)
          minutes ? minutes * 60 : STALLED_AFTER
        end

        # Settles a stalled claim as failed, warns once and logs the finding that names the row.
        def abandon_stalled(row, repository)
          abandon(row, repository, abandoned_reason(row), by: "the boot")
          warn stalled_wording(row)
          @log << { outbox: row.delivery_id, consumer: row.consumer, kind: row.kind, stalled: true, abandoned: true,
                    event: row.event[:name], aggregate: row.event[:aggregate], id: row.event[:id] }
        end

        def abandoned_reason(row)
          "claimed #{row.claimed_seconds_ago || "an unknown time"}s before the last crash/restart and never settled"
        end

        def stalled_wording(row)
          "[hecks] outbox row #{row.delivery_id} (#{row.consumer} on #{row.event[:name]} for " \
            "#{row.event[:aggregate]}##{row.event[:id]}) was claimed before the last crash/restart and never " \
            "settled — its #{row.kind} may or may not have actually run. It is now settled as failed and was not " \
            "redelivered (redelivering it could double the effect); this is the only time it is named. If its " \
            "effect did not land, issue the command again by hand."
        end
      end
    end
  end
end
