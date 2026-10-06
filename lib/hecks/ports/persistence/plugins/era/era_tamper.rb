require "json"
require "tempfile"
require_relative "era_guard"
require_relative "storage_shape"

module Hecks
  module Runtime
    # Wording for the boot refusal when a held era's frozen text was
    # edited after freezing (detected elsewhere via a digest mismatch).
    #
    # Lives here, not under `Ports::Persistence`, because `project` below
    # calls runtime DSL-execution machinery (`EraGuard`, `StorageShape`) directly.
    module EraTamper
      module_function

      # Words the boot refusal for a held era text whose digest does not match.
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
      # Always parsed from a fresh tempfile, never the held file's own path,
      # since the predicate extractor caches source by path and would see stale lines there.
      #
      # @param text [String] the bluebook source to parse
      # @param _source_path [String, nil] ignored; the text is always parsed from a tempfile
      # @return [Hash{String => Object}, nil] `StorageShape.project`'s Hash after a JSON
      #   round-trip; nil when the text declares no bluebook, or when parsing or projecting
      #   raises any `StandardError` or `SyntaxError`
      def project(text, _source_path = nil)
        bluebook = parse_from_tempfile(text)
        return nil unless bluebook

        JSON.parse(JSON.generate(StorageShape.project(bluebook)))
      rescue StandardError, SyntaxError
        nil
      end

      # Parses the text from a tempfile that is removed afterwards.
      #
      # @param text [String] the bluebook source
      # @return [Bluebook::Chapter, nil] the parsed bluebook; nil when the text declares none
      def parse_from_tempfile(text)
        file = Tempfile.new(["hecks-tamper-", ".bluebook"])
        file.write(text)
        file.flush
        EraGuard.shadow_parse(text, file.path)
      ensure
        file&.close!
      end
    end
  end
end
