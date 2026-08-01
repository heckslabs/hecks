require "json"
require "tempfile"

module Hecksagain
  module Ports
    module Persistence
      # The verdict behind an integrity refusal: when a held era text
      # fails its digest, the operator's first question is "did the edit
      # change what this era MEANT, or only its words?" — and answering
      # it needs no minting machinery, only the structural comparison
      # every boot already trusts: project the edited text and compare
      # it to the projection frozen beside the era. Both runtimes can do
      # this (Rust included — no hashing, no canonical serialization),
      # so a Rust-only deployment learns which situation it is in at
      # 3am, even though the repair tool itself is Ruby.
      #
      # The refusal wordings here are byte-identical with the Rust twin
      # (rust/src/ports/persistence/era_store.rs). One accepted corner
      # divergence: an edited text Ruby cannot parse falls back to the
      # generic wording, while Rust's permissive parser always reaches a
      # verdict — two different judgments about the same input, the same
      # principle as the host-language strictness note.
      module EraTamper
        module_function

        def refusal(domain:, ordinal:, edited_text:, stored_projection:, source_path: nil)
          base = "cannot boot #{domain}: the held text of era #{ordinal} was edited after it was frozen"
          if stored_projection
            edited = project(edited_text, source_path)
            if edited && edited == stored_projection
              return "#{base} — the edit is cosmetic to the storage shape; " \
                     "re-attest it (bin/reattest_era), or restore the original text from the era archive"
            end
            if edited
              return "#{base} AND the edit changed the storage shape — " \
                     "re-attestation will refuse it; restore the original text from the era archive"
            end
          end
          "#{base} — held era texts are storage facts; restore the original text, or reset the data"
        end

        # The storage-shape projection of a bluebook text, JSON-normalized
        # for structural comparison against a stored projection; nil when
        # the text does not load. ALWAYS parsed through a fresh tempfile,
        # never the held file's own path: the predicate extractor caches
        # source by path, and a held path whose content has changed (the
        # very situation this module exists for) would hand it stale
        # lines.
        def project(text, _source_path = nil)
          file = Tempfile.new(["hecks-tamper-", ".bluebook"])
          begin
            file.write(text)
            file.flush
            bluebook = Runtime::EraGuard.shadow_parse(text, file.path)
          ensure
            file.close!
          end
          return nil unless bluebook

          JSON.parse(JSON.generate(Runtime::StorageShape.project(bluebook)))
        rescue StandardError, SyntaxError
          nil
        end
      end
    end
  end
end
