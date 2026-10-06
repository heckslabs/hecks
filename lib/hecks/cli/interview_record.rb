module Hecks
  module CLI
    # The Markdown record of an interview, and the plain interview read out of a booted record.
    # `InterviewDraft` extends it.
    module InterviewRecord
      # The keys each kind of finding carries into the plain interview, in the order they are read.
      FINDING_KEYS = {
        things:      [:number, :name, :identifier, :source, :status],
        actions:     [:number, :name, :thing, :event, :creates, :takes, :by, :source, :status],
        rules:       [:number, :statement, :source, :status],
        fields:      [:number, :thing, :name, :values, :source, :status],
        transitions: [:number, :thing, :action, :to, :from, :source, :status]
      }.freeze

      # The interview's record: every exchange in order, and every finding with how it was decided.
      #
      # @param interview [Hash] the interview
      # @return [String] Markdown
      def record(interview)
        lines = ["# Interview #{interview.fetch(:reference)}: #{interview.fetch(:subject)}", "",
                 "Expert: #{interview.fetch(:expert)}", "", "## Exchanges", ""]
        interview.fetch(:exchanges).each_with_index { |ex, i| lines.concat(exchange_lines(ex, i + 1)) }
        lines << "" << "## Findings" << ""
        lines.concat(finding_lines(interview))
        "#{lines.join("\n")}\n"
      end

      # Reads the plain interview out of an `Interview` record booted from the SME chapter.
      #
      # @param interview [Object] the booted record
      # @return [Hash] the plain interview this module takes: `reference`, `subject`, `expert`,
      #   `exchanges` (`question`, `answer`, `topic`), and `things`, `actions`, `rules`,
      #   `fields` and `transitions`, each a finding with its `number`, `source` and `status`
      #   and the fields of its kind
      def from_record(interview)
        plain_interview = { reference: plain(interview.reference), subject: plain(interview.subject),
                            expert: plain(interview.expert),
                            exchanges: interview.exchanges.map { |ex| slice(ex, :question, :answer, :topic) } }
        FINDING_KEYS.each { |kind, keys| plain_interview[kind] = plain_findings(interview, kind, keys) }
        plain_interview
      end

      # @api private
      def plain_findings(interview, kind, keys)
        interview.public_send(:"#{kind.to_s.chomp("s")}_findings").map { |finding| slice(finding, *keys) }
      end

      # @api private
      def record_file(interview, tail = "")
        { "interviews/#{file_stem(interview.fetch(:reference))}.md" => record(interview) + tail }
      end

      # @api private
      def file_stem(reference) = reference.to_s.gsub(/[^A-Za-z0-9._-]/, "_")

      # @api private
      def exchange_lines(exchange, number)
        lines = ["#{number}. **Q:** #{one_line(exchange[:question])}", "   **A:** #{one_line(exchange[:answer])}"]
        topic = exchange[:topic].to_s
        lines << "   _Topic: #{one_line(topic)}_" unless topic.empty?
        lines
      end

      # @api private
      def finding_lines(interview)
        interview.fetch(:things).map { |f| thing_line(f) } +
          interview.fetch(:actions).map { |f| action_line(f) } +
          shape_finding_lines(interview) +
          interview.fetch(:rules).map { |f| rule_line(f) }
      end

      # The field and transition findings, which an interview may not carry at all.
      # @api private
      def shape_finding_lines(interview)
        interview.fetch(:fields, []).map { |f| field_line(f) } +
          interview.fetch(:transitions, []).map { |f| transition_line(f) }
      end

      # @api private
      def thing_line(finding)
        "- Thing #{finding[:number]}, #{finding[:status]}: **#{finding[:name]}**, " \
          "identified by `#{finding[:identifier]}` (exchange #{finding[:source]})"
      end

      # @api private
      def action_line(finding)
        creates = finding[:creates] ? ", creates it" : ""
        "- Action #{finding[:number]}, #{finding[:status]}: **#{finding[:name]}** on #{finding[:thing]}, " \
          "announcing `#{finding[:event]}`#{creates}#{clause("takes", finding[:takes])}" \
          "#{clause("by", finding[:by])} (exchange #{finding[:source]})"
      end

      # @api private
      def field_line(finding)
        "- Field #{finding[:number]}, #{finding[:status]}: **#{finding[:name]}** on #{finding[:thing]}" \
          "#{clause("one of", finding[:values])} (exchange #{finding[:source]})"
      end

      # @api private
      def transition_line(finding)
        from = finding[:from].to_s.strip.empty? ? "" : " from #{finding[:from]}"
        "- Transition #{finding[:number]}, #{finding[:status]}: **#{finding[:action]}** on #{finding[:thing]} " \
          "to #{finding[:to]}#{from} (exchange #{finding[:source]})"
      end

      # @api private
      def rule_line(finding)
        "- Rule #{finding[:number]}, #{finding[:status]}: #{one_line(finding[:statement])} (exchange #{finding[:source]})"
      end

      # A `, label value` clause, or nothing when the value is blank.
      # @api private
      def clause(label, value) = value.to_s.strip.empty? ? "" : ", #{label} #{value}"

      # @api private
      def one_line(text) = text.to_s.gsub(/\s+/, " ").strip

      # @api private
      def plain(value)
        return nil if value.nil?

        found = value.respond_to?(:to_h) && !value.is_a?(String) ? value.to_h : value
        found.is_a?(Hash) && found.key?(:value) ? found[:value] : found
      end

      # @api private
      def slice(record, *keys) = keys.to_h { |key| [key, plain(record[key])] }
    end
  end
end
