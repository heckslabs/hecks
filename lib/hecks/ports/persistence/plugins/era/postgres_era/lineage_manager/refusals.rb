module Hecks
  module Adapters
    class PostgresEra
      module LineageManager
        # The refusals a mint raises: toward the scaffold when no edge exists, and for a forked,
        # stale or unapproved edge. Each is built from the era check's `Context`.
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

          # Whether the journal already holds an approval of this edge at the journal's tip.
          def approved_at_tip?(approval, digest, tip)
            approval && approval[:edge_digest] == digest && approval[:reviewed_ordinal] == tip
          end

          def refuse_unapproved!(context, edge, approval, tip)
            if approval && approval[:edge_digest] == Translation::Audit.edge_digest(edge)
              raise era_refusal(context, "the journal advanced past the approved " \
                                         "review (ordinal #{approval[:reviewed_ordinal]} reviewed, #{tip} now) — the samples a " \
                                         "human approved no longer cover the data; re-run hecks audit_translation with --approve")
            end

            mismatch = Translation::ApprovalFile.host_mismatch(context.directory, edge)
            raise era_refusal(context, unapproved_reason(mismatch))
          end

          def unapproved_reason(mismatch)
            return "the committed approval does not apply — #{mismatch}" if mismatch

            "this edge carries a compute or rekey " \
              "rule, and the audit's human-approved sample is its only verification — run " \
              "hecks audit_translation with --approve, then boot again"
          end

          # Builds the refusal; a mint's own refusals say "cannot mint era N of X", the
          # edge-resolution ones say "cannot boot X".
          def era_refusal(context, text, minting: true)
            name = context.bluebook.name
            lead = minting ? "cannot mint era #{context.ordinal} of #{name}" : "cannot boot #{name}"
            Runtime::WiringError.new("#{lead}: #{text}")
          end
        end
      end
    end
  end
end
