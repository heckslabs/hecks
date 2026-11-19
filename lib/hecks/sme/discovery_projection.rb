require_relative "discovery_projection/statement"
require_relative "discovery_projection/aggregate_text"
require_relative "discovery_projection/staged_check"

module Hecks
  # The SME chapter: what remains of ADR 0088's interview once Interviews holds the conversation
  # (ADR 0194, decision 6).
  module SME
    # The discovery projection: turns an interview's accepted discovery Points into bluebook text
    # and checks it staged (ADR 0194, decisions 4 and 10).
    #
    # Pure up to `check`: `text` answers the bluebook and writes nothing. A Point is a Hash with
    # `:number`, `:kind`, `:statement`, `:source` (its exchange) and `:status`, the shape of a
    # Point in the Interviews bluebook. Only accepted Points of a discovery kind are read; `work`
    # and `decision` fan out on their own events, and any other kind is recorded and no more.
    # Statements are read by `Statement`; whatever it cannot read is kept as a cited comment.
    module DiscoveryProjection
      # The kinds that are bluebook lines.
      KINDS = %w[thing action field rule transition].freeze
      ACCEPTED = "accepted".freeze
      # A run of letters and digits: one word of a subject.
      SUBJECT_WORD = /[A-Za-z0-9]+/
      # A name that starts with a letter, as a bluebook name must.
      LETTER_FIRST = /\A[A-Za-z]/

      module_function

      # @param subject [String] the interview's subject, which names the bluebook
      # @param points [Array<Hash>] the interview's Points, in any state
      # @return [String] the bluebook text of the accepted discovery Points
      def text(subject:, points:)
        accepted = points.select { |p| p[:status] == ACCEPTED && KINDS.include?(p[:kind]) }
        name = bluebook_name(subject)
        body = ["Hecks.bluebook #{name.inspect} do", "  vision #{vision(subject).inspect}", "  core"] +
               Layout.new(accepted).lines + ["end"]
        "#{body.join("\n")}\n"
      end

      # Projects the Points and checks the text staged in a temporary directory.
      #
      # @param subject [String] the interview's subject
      # @param points [Array<Hash>] the interview's Points
      # @return [Hash] `:text`, the bluebook text, and `:verdict`, a `StagedCheck::Verdict`
      def check(subject:, points:)
        projected = text(subject: subject, points: points)
        { text: projected, verdict: StagedCheck.call(projected) }
      end

      # The comment that heads every projected line, naming its Point and exchange.
      #
      # @param point [Hash] a Point
      # @return [String] the comment, indented for the bluebook body
      def cite(point)
        "  # #{point[:kind]}, point #{point[:number]} (exchange #{point[:source]})"
      end

      # @param text [String, nil] a statement
      # @return [String] the statement on one line
      def flat(text) = text.to_s.split.join(" ")

      # @api private
      def bluebook_name(subject)
        words = flat(subject).scan(SUBJECT_WORD).map { |word| Statement.capital(word) }.join
        words.match?(LETTER_FIRST) ? words : "Discovery#{words}"
      end

      # @api private
      def vision(subject) = "Discovery points accepted in an interview about #{flat(subject)}."
    end
  end
end

require_relative "discovery_projection/layout"
