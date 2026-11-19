require_relative "concluded_record/markdown"

module Hecks
  # Interviews: work begins in a conversation, and the conversation is kept (ADR 0194).
  module Interviews
    # The concluded record: an interview of Hecks's own, projected to
    # `docs/interviews/<reference>.md` (ADR 0194, decision 7).
    #
    # Pure: it answers the file to write and writes nothing, as `ProjectionFiles.build` does, and
    # the caller writes it and commits it with the ADR the interview produced. An interview is a
    # Hash in the shape of the Interviews bluebook's Interview: `:reference`, `:subject`,
    # `:keeping`, `:exchanges` (each `:speaker`, `:answer`, `:question`) and `:points` (each
    # `:number`, `:kind`, `:statement`, `:source`, `:supersedes`, `:status`). Only an interview
    # whose keeping is `committed` has a record; any other keeping, or none, is an outside expert's
    # and has no path, so a client's details never reach `docs/`.
    module ConcludedRecord
      # The keeping of an interview of Hecks's own, whose record is committed: one of the values
      # the Keeping value object allows (lib/hecks/interviews/interviews.bluebook, `Keeping`).
      COMMITTED = "committed".freeze
      # Where the records sit, under the checkout.
      DIRECTORY = File.join("docs", "interviews").freeze
      # A reference that is one plain file name: a letter or digit, then letters, digits, `.`,
      # `_` or `-`. A slash, a backslash, a null byte, a leading dot and an empty name all fail it.
      REFERENCE = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

      module_function

      # @param root [String] the checkout
      # @param interview [Hash] a concluded interview
      # @return [Hash{String => String}] the record's path and text, or empty for a local interview
      def files(root:, interview:)
        target = path(root: root, interview: interview)
        target ? { target => text(interview) } : {}
      end

      # @param root [String] the checkout
      # @param interview [Hash] a concluded interview
      # @return [String, nil] `docs/interviews/<reference>.md` under the root, or nil when local
      # @raise [ArgumentError] when the reference is not one plain file name
      def path(root:, interview:)
        return nil unless interview[:keeping] == COMMITTED

        File.join(root, DIRECTORY, "#{file_name(interview[:reference])}.md")
      end

      # @param interview [Hash] a concluded interview
      # @return [String] the record as Markdown: its exchanges, then its Points citing them
      def text(interview) = "#{Markdown.lines(interview).join("\n")}\n"

      # @param reference [String, nil] the interview's reference
      # @return [String] the reference, when it is one plain file name
      # @raise [ArgumentError] otherwise
      def file_name(reference)
        name = reference.to_s
        return name if name.match?(REFERENCE)

        raise ArgumentError, "an interview reference is one plain file name, not #{name.inspect}"
      end
    end
  end
end
