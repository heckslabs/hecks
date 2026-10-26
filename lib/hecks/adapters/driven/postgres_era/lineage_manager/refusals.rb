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

          private

          def refuse_forked_eras!(context, edges)
            latest = context.latest
            raise era_refusal(context, "#{edges.size} translation edges leave era #{latest[:ordinal]} " \
                                       "(#{latest[:label]}) — eras fork mechanically; keep one edge per source shape",
                              minting: false)
          end

          def refuse_stale_edge!(context, edge)
            return if edge.to == context.label

            raise era_refusal(context, "the translation edge from #{context.latest[:label]} targets " \
                                       "#{edge.to}, but the current shape is #{context.label} — the edge is stale; " \
                                       "re-run hecks scaffold_translation", minting: false)
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
