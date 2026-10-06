# frozen_string_literal: true

require "json"
require "digest"

module Hecks
  module Adapters
    class JournalStore
      module Readings
        # The text a person reads before attesting to an era whose held text differs from its
        # digest.
        module Attestation
          private

          def attest(held, lineage, ordinal)
            era = raw_era(held, lineage, ordinal)
            computed = Digest::SHA256.hexdigest(era[:held_text])
            return "#{era_name(held, ordinal)}: the held text matches its digest — nothing to re-attest." if
              era[:held_digest] == computed

            mismatch(held, era, ordinal, computed)
          end

          def era_name(held, ordinal) = "#{held.bluebook.name} era #{ordinal}"

          def mismatch(held, era, ordinal, computed)
            [
              "#{era_name(held, ordinal)}: the held text does NOT match its recorded digest.",
              "  recorded: #{era[:held_digest] || "(none)"}", "  computed: #{computed}",
              shape_line(held, era, ordinal),
              "The held text AS IT NOW STANDS — the original is gone; this is what you would be attesting to:",
              "─" * 72, era[:held_text], "─" * 72,
              "Read it, then `hecks reattest #{held.bluebook.name} era=#{ordinal} --confirm` accepts it."
            ].join("\n")
          end

          def shape_line(held, era, ordinal)
            verdict = Translation::Reattest.shape_guard!(
              domain: held.bluebook.name, ordinal: ordinal, text: era[:held_text], stored_hash: era[:hash],
              stored_projection: era[:held_projection] && JSON.parse(era[:held_projection])
            )
            if verdict == :cosmetic
              "  shape:    unchanged — the edit is cosmetic (the text still projects to era #{ordinal}'s minted name)"
            else
              "  shape:    era #{ordinal} was never named, so no shape comparison is possible — read carefully"
            end
          end
        end
      end
    end
  end
end
