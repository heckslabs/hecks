require "json"
require "tempfile"
require_relative "era_guard"
require_relative "storage_shape"

module Hecks
  module Runtime
    # The refusal wording for a held era whose digest no longer matches its
    # frozen text — the digest mismatch alone is what detects tampering (a
    # plain SHA256 comparison over raw bytes, unrelated to any of this);
    # this only supplies the wording once that's already fired.
    #
    # Lives here, not under `Ports::Persistence` — `project` below directly
    # calls `Runtime::EraGuard.shadow_parse`/`Runtime::StorageShape.project`
    # (DSL-execution machinery), the "an adapter/port reaches into the
    # runtime instead of being handed already-computed data" shape that
    # has caused trouble here before. A capability this dependent on the
    # runtime is a runtime-owned one that the Postgres adapter calls, not
    # a ports-level module that happens to reach sideways into it.
    #
    # Every tamper refusal reaches the same generic wording, cosmetic edit
    # or real shape change alike: telling the two apart by re-parsing the
    # edited text is a pure quality-of-message nicety, not a safety
    # property, and an edit that cannot be classified has to fall to the
    # generic wording anyway. An operator judges "did this matter"
    # themselves, reading the still-archived original — an anomalous
    # recovery moment already, not a normal boot path.
    module EraTamper
      module_function

      # Words the boot refusal for a held era text whose digest no longer matches.
      #
      # @param domain [String] name of the domain whose era was edited
      # @param ordinal [Integer] the edited era's ordinal in `hecks_eras`
      # @return [String] the refusal message, ready to raise as a `Runtime::WiringError`
      def refusal(domain:, ordinal:)
        "cannot boot #{domain}: the held text of era #{ordinal} was edited after it was frozen — " \
          "held era texts are storage facts; restore the original text, or reset the data"
      end

      # Parses a bluebook text and returns its storage-shape projection.
      #
      # The projection is JSON-normalized for structural comparison
      # against a stored projection; nil when the text does not load.
      # Always parsed through a fresh tempfile, never the held file's own
      # path: the predicate extractor caches source by path, and a held
      # path whose content has changed (the very situation this module
      # exists for) would hand it stale lines.
      #
      # @param text [String] the bluebook source to parse
      # @param _source_path [String, nil] ignored; the text is always parsed from a tempfile
      # @return [Hash{String => Object}, nil] `StorageShape.project`'s Hash after a JSON
      #   round-trip; nil when the text declares no bluebook, or when parsing or projecting
      #   raises any `StandardError` or `SyntaxError`
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
