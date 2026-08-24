require "json"
require "tempfile"
require_relative "era_guard"
require_relative "storage_shape"

module Hecks
  module Runtime
    # The refusal wording for a held era whose digest no longer matches its
    # frozen text — the digest mismatch alone is what DETECTS tampering (a
    # plain SHA256 comparison over raw bytes, unrelated to any of this);
    # this only supplies the wording once that's already fired.
    #
    # LIVES HERE, NOT UNDER `Ports::Persistence` — `project` below directly
    # calls `Runtime::EraGuard.shadow_parse`/`Runtime::StorageShape.project`
    # (DSL-execution machinery), the "an adapter/port reaches into the
    # runtime instead of being handed already-computed data" shape that
    # has caused trouble here before. A capability this dependent on the
    # runtime is a runtime-owned one that the Postgres adapter CALLS, not
    # a ports-level module that happens to reach sideways into it.
    #
    # Used to also distinguish a cosmetic edit from a real shape change
    # here, by re-parsing the edited text — a pure quality-of-message
    # nicety, not a safety property, since dropped: every tamper refusal
    # reaches the same generic wording now, the one this already fell to
    # whenever it couldn't classify an edit anyway. An operator judges
    # "did this matter" themselves,
    # reading the still-archived original — an anomalous recovery moment
    # already, not a normal boot path.
    module EraTamper
      module_function

      def refusal(domain:, ordinal:)
        "cannot boot #{domain}: the held text of era #{ordinal} was edited after it was frozen — " \
          "held era texts are storage facts; restore the original text, or reset the data"
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
