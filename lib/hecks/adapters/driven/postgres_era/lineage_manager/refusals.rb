module Hecks
  module Adapters
    class PostgresEra
      module LineageManager
        # The refusals a mint raises: toward the scaffold when no edge exists, and for a forked or
        # stale edge. Each is built from the era check's `Context`.
        module Refusals
          # Refuses toward the authoring loop, or, under HECKS_SCAFFOLD=1, scaffolds the
          # missing edge first and names the file it wrote.
          def refuse_toward_the_scaffold!(context)
            if ENV["HECKS_SCAFFOLD"] == "1" && context.directory
              path = scaffold!(context.registry, context.bluebook, context.lineage, context.latest, context.directory)
              raise era_refusal(context, "the shape changed (era #{context.ordinal}) — wrote #{path}; " \
                                         "review it (resolve every unresolved), check it with hecks audit_translation, " \
                                         "then boot again", minting: false)
            end

            raise era_refusal(context, "the shape changed (era #{context.ordinal}) and no translation edge " \
                                       "covers it — run hecks scaffold_translation to write the edge, " \
                                       "check it with hecks audit_translation, then boot again", minting: false)
          end

          # Refuses to move a database to a newer shape from a copy that may not mint: minting
          # migrates what every other checkout of the domain reads, and an older checkout is then
          # refused until it catches up.
          def refuse_unpermitted_mint!(context)
            latest = context.latest
            raise era_refusal(context, "a translation edge covers the move from era #{latest[:ordinal]} " \
                                       "(#{latest[:label]}) to #{context.label}, but this copy may not mint: " \
                                       "it would migrate a database other checkouts read. Mint from the copy " \
                                       "that owns the database, by declaring `mint_eras true` in the " \
                                       "persisted_by block of its world", minting: false)
          end

          # Refuses a mint that the rehearsal does not back: not confirmed, not a would_mint verdict, or a
          # ledger watermark that moved since the rehearsal read it.
          def refuse_unrehearsed_mint!(context)
            request = context.mint_request
            raise era_refusal(context, "the mint was not confirmed") unless request.confirm
            unless request.verdict == "would_mint"
              raise era_refusal(context, "the rehearsal's verdict was #{request.verdict}, not would_mint; " \
                                         "rehearse again")
            end

            refuse_moved_watermark!(context, request.watermark)
          end

          private

          def refuse_moved_watermark!(context, watermark)
            current = context.watermark
            return if current == watermark

            raise era_refusal(context, "the ledger watermark moved from #{watermark} to #{current} since the " \
                                       "rehearsal; rehearse again")
          end

          def refuse_duplicate_edges!(context, edges)
            latest = context.latest
            raise era_refusal(context, "#{edges.size} translation edges lead era #{latest[:ordinal]} " \
                                       "(#{latest[:label]}) to the current shape #{context.label}; keep one",
                              minting: false)
          end

          # Builds the refusal; a mint's own refusals say "cannot mint era N of X", the
          # edge-resolution ones say "cannot boot X".
          def era_refusal(context, text, minting: true)
            name = context.domain_name
            lead = minting ? "cannot mint era #{context.ordinal} of #{name}" : "cannot boot #{name}"
            Runtime::WiringError.new("#{lead}: #{text}")
          end
        end
      end
    end
  end
end
