require "hecks"
require_relative "../adapters/driving/admission"
require_relative "plain"

module Hecks
  module Composer
    # The editor's own bookkeeping, held in memory: one Composer chapter booted for the life of the
    # server, with a `Draft` per chapter being edited. The files on disk stay the truth; the draft
    # keeps the text last seen, the conversation about it, and what its last check said, so the
    # page can show a history and an agent's turns survive a refresh.
    class Session
      CHAPTER_DIR = File.expand_path("bluebook", __dir__).freeze
      VERB = "Composer::Draft".freeze

      # A `Hecks.<construct> "Name"` header, capturing the chapter's name.
      CHAPTER_DECLARATION = /Hecks\.\w+\s+"([A-Z][A-Za-z0-9]*)"/

      # @return [Runtime::Dispatcher] the booted Composer chapter
      attr_reader :runtime

      # Boots the Composer chapter, which admits only the `Web` driving adapter.
      #
      # @raise [Adapters::Driving::Admission::Refused] if the hecksagon does not admit `Web`
      def initialize
        @runtime = Hecks.boot(CHAPTER_DIR, install_driving: false, environment: "memory")
        Adapters::Driving::Admission.admit!(@runtime.registry, "Web")
        @sequence = Hash.new(0)
      end

      # Opens a draft for a chapter, or leaves an open one as it is.
      #
      # @param slug [String] the draft's name
      # @param chapter_name [String] the chapter's name
      # @param text [String] the text it starts from
      # @return [void]
      def open(slug:, chapter_name:, text:)
        return if draft(slug)

        dispatch("Begin", slug: wrap(slug), chapter_name: wrap(chapter_name), text: wrap(text))
      end

      # Records the text now on screen.
      # @param slug [String] the draft's name
      # @param text [String] the text
      # @return [void]
      def revise(slug:, text:)
        dispatch("Revise", to: slug, text: wrap(text))
      end

      # Keeps the text of one workspace file, one draft per file with the path as its slug: the
      # first record of a path begins its draft, later ones revise it.
      #
      # @param path [String] the file's path relative to the workspace
      # @param text [String] the text now on screen
      # @return [void]
      def record(path:, text:)
        return revise(slug: path, text: text) if draft(path)

        self.open(slug: path, chapter_name: chapter_name_in(text), text: text)
      end

      # The text a file has held, from the chapter's own events.
      #
      # @param path [String] the file's path relative to the workspace
      # @return [Array<Hash>] `name`, `at` and `text` per recorded revision, newest first; empty
      #   when the path was never recorded (`text` is nil for an event that carries none)
      def timeline(path)
        @runtime.events.filter_map { |event| revision(event.to_h, path) }.reverse
      end

      # Records a check's verdict: accepted when it found no refusal, rejected with its words
      # when it did.
      #
      # @param slug [String] the draft's name
      # @param diagnostic [Hash, nil] the check's refusal, or nil
      # @return [void]
      def judge(slug:, diagnostic:)
        return dispatch("Accept", to: slug, note: wrap("ok")) unless diagnostic

        where = diagnostic[:line] ? "#{diagnostic[:file]}:#{diagnostic[:line]} " : ""
        dispatch("Reject", to: slug, note: wrap(where + diagnostic[:message].to_s))
      end

      # Puts the author's request into the draft's conversation.
      # @param slug [String] the draft's name
      # @param said [String] the request
      # @return [void]
      def ask(slug:, said:)
        dispatch("Ask", to: slug, sequence: wrap(next_sequence(slug)), said: wrap(said))
      end

      # Puts the agent's reply into the draft's conversation, with the text it left behind.
      #
      # @param slug [String] the draft's name
      # @param said [String] the reply
      # @param text [String] the text the draft holds after the agent's edit
      # @return [void]
      def answer(slug:, said:, text:)
        dispatch("Answer", to: slug, sequence: wrap(next_sequence(slug)), said: wrap(said), text: wrap(text))
      end

      # @param slug [String] the draft's name
      # @return [Hash, nil] the draft as the chapter holds it, or nil when none is open
      def draft(slug)
        drafts.find(slug)&.then { |row| plain(row) }
      rescue StandardError
        nil
      end

      # The draft in plain terms, for the page.
      #
      # @param slug [String] the draft's name
      # @return [Hash, nil] `status`, `note` and `turns` (`sequence`, `speaker`, `said`), or nil
      def summary(slug)
        held = draft(slug) or return nil
        { status: held[:status], note: Plain.call(held[:note]), turns: Plain.call(Array(held[:turns])) }
      end

      private

      # @api private
      def chapter_name_in(text) = text[CHAPTER_DECLARATION, 1] || "Workspace"

      # @api private
      def revision(event, path)
        return unless event[:aggregate] == VERB && event[:id] == path

        { name: event[:name], at: event[:occurred_at], text: Plain.call(event[:payload])&.dig(:text) }
      end

      def aggregate = @runtime.registry.bluebook("Composer").aggregate("Draft")

      # @api private
      def drafts = @runtime.registry.repository("Composer", aggregate)

      def dispatch(command, to: nil, **facts)
        @runtime.dispatch("#{VERB}.#{command}", to: to, with: facts)
      end

      def wrap(value) = { value: value }

      def next_sequence(slug) = @sequence[slug] += 1

      def plain(row) = row.respond_to?(:to_h) ? row.to_h : row
    end
  end
end
