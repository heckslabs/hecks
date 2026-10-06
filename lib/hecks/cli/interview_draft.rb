require_relative "../naming"
require_relative "domain_stub"
require_relative "interview_shape"
require_relative "interview_record"
require_relative "interview_aggregate"

module Hecks
  module CLI
    # Turns an interview's accepted findings into the files of a first domain (ADR 0088).
    #
    # Pure: it answers the text of each file and writes none, so the command that runs an interview
    # can check every target before it writes the first, and a spec can boot the result. It shares
    # the files around a bluebook with `hecks init` (`DomainStub.support_files`) and renders the
    # bluebook itself, from what the developer accepted, where `init` writes a fixed stub.
    #
    # Only `accepted` findings reach the bluebook; every finding reaches the record. A rule is never
    # turned into code from prose: it is a comment citing its source, to become a `given` by hand.
    module InterviewDraft
      ACCEPTED = "accepted".freeze

      extend InterviewRecord
      extend InterviewAggregate

      module_function

      # The files a first interview writes: the bluebook, the files around it, and the record.
      #
      # @param interview [Hash] the interview, with at least one accepted thing
      # @param adapter [String, nil] an adapter in `DomainStub::ADAPTERS`; its default when nil
      # @return [Hash{String => String}] each file's path under the domain directory, and its text
      # @raise [ArgumentError] when nothing was accepted, or the subject or adapter is refused
      def files(interview, adapter: nil)
        name = interview.fetch(:subject)
        support = DomainStub.support_files(name: name, adapter: adapter)
        { "bluebook/#{Naming.snake(name)}.bluebook" => bluebook(interview) }
          .merge(support)
          .merge(record_file(interview))
      end

      # What a later interview writes: its record, ending in the aggregates and commands it would
      # add, for a developer to merge. An existing domain is never touched (ADR 0088).
      #
      # @param interview [Hash] the interview
      # @return [Hash{String => String}] the one file, `interviews/<reference>.md`
      def additions(interview)
        record_file(interview, "\n## Proposed additions\n\nMerge by hand into the domain's bluebook.\n\n" \
                               "```ruby\n#{fragment(interview)}```\n")
      end

      # @api private
      def bluebook(interview)
        name = interview.fetch(:subject)
        raise ArgumentError, "nothing was accepted: a draft needs at least one thing" if accepted(interview, :things).empty?

        out = ["Hecks.bluebook #{name.inspect} do"] + header(interview) +
              [%(  vision "TODO: say in one sentence what #{name} is for."), "  supporting", ""] +
              rule_lines(interview) + [fragment(interview).chomp, "end"]
        "#{out.join("\n")}\n"
      end

      # The aggregates, with their commands: the part a later interview offers to merge.
      # @api private
      def fragment(interview)
        things = accepted(interview, :things).uniq { |t| word(t[:name]) }
        actions = accepted(interview, :actions)
        blocks = things.map { |thing| aggregate(interview, thing, actions) }
        loose = loose_actions(things, actions)
        blocks << unplaced(interview, loose) unless loose.empty?
        "#{blocks.join("\n\n")}\n"
      end

      # The accepted actions whose thing nobody accepted.
      # @api private
      def loose_actions(things, actions)
        placed = things.map { |t| word(t[:name]) }
        actions.reject { |a| placed.include?(word(a[:thing])) }
      end

      # @api private
      def header(interview)
        ["  # Drafted from interview #{interview[:reference]} with #{interview[:expert]}. Each name below cites the",
         "  # exchange it came from; edit freely."]
      end

      # @api private
      def rule_lines(interview)
        rules = accepted(interview, :rules)
        return [] if rules.empty?

        ["  # RULES the expert gave, for you to turn into `given` clauses:"] +
          rules.map { |r| "  #   - #{cite(interview, r)} #{one_line(r[:statement])}" } + [""]
      end

      # @api private
      def accepted(interview, kind) = interview.fetch(kind, []).select { |finding| finding[:status] == ACCEPTED }

      # A free-text name as a PascalCase word safe to write into Ruby: `lend a book` is `LendABook`.
      # @api private
      def word(text) = text.to_s.split(/[^A-Za-z0-9]+/).reject(&:empty?).map { |part| part.sub(/\A./, &:upcase) }.join

      # @api private
      def cite(interview, finding) = "#{interview[:reference]} ##{finding[:source]}:"

      # Where a name came from: the interview, the exchange, and a short quotation of the answer.
      # @api private
      def source_note(interview, finding)
        exchange = interview.fetch(:exchanges)[finding[:source].to_i - 1]
        note = "from #{cite(interview, finding)}"
        return note unless exchange

        text = one_line(exchange[:answer])
        text = "#{text[0, 77]}..." if text.length > 80
        "#{note} #{text.inspect}"
      end
    end
  end
end
