require "json"
require "tempfile"
require_relative "era_guard"
require_relative "storage_shape"

module Hecksagain
  module Runtime
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
    # LIVES HERE, NOT UNDER `Ports::Persistence` — it directly calls
    # `Runtime::EraGuard.shadow_parse`/`Runtime::StorageShape.project`
    # (DSL-execution machinery), the same "an adapter/port reaches into
    # the runtime instead of being handed already-computed data" shape
    # Rust's own `postgres_repository.rs` had, calling `storehouse::
    # parser` directly, before that arc gated it. A capability this
    # dependent on the runtime is a runtime-owned one that the Postgres
    # adapter CALLS, not a ports-level module that happens to reach
    # sideways into it.
    #
    # The refusal wordings here are byte-identical with the Rust twin
    # (rust/postgres/src/postgres_repository.rs). One accepted corner
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
          bluebook = EraGuard.shadow_parse(text, file.path)
        ensure
          file.close!
        end
        return nil unless bluebook

        JSON.parse(JSON.generate(StorageShape.project(bluebook)))
      rescue StandardError, SyntaxError
        nil
      end
    end
  end
end
