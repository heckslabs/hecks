require_relative "../naming"
require_relative "domain_stub"
require_relative "interview_shape"

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

      # The pattern every generated string field carries: it refuses a blank value.
      PATTERN = %q('[^ \t\n\r]').freeze

      # What stands in for a creating command nothing in the interview named.
      STUB_NOTE = "    # TODO: no action that creates was accepted; replace Create with the real one.".freeze

      # One accepted thing: what it is called and identified by, its fields, its transitions, the
      # actions that create it and the others.
      Shape = Struct.new(:name, :identifier, :type, :fields, :steps, :creating, :rest, keyword_init: true)
      private_constant :PATTERN, :STUB_NOTE, :Shape

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
        { reference: plain(interview.reference), subject: plain(interview.subject), expert: plain(interview.expert),
          exchanges: interview.exchanges.map { |ex| slice(ex, :question, :answer, :topic) },
          things:    interview.thing_findings.map { |f| slice(f, :number, :name, :identifier, :source, :status) },
          actions:   interview.action_findings.map do |f|
            slice(f, :number, :name, :thing, :event, :creates, :takes, :by, :source, :status)
          end,
          rules:     interview.rule_findings.map { |f| slice(f, :number, :statement, :source, :status) },
          fields:    interview.field_findings.map { |f| slice(f, :number, :thing, :name, :values, :source, :status) },
          transitions: interview.transition_findings.map do |f|
            slice(f, :number, :thing, :action, :to, :from, :source, :status)
          end }
      end

      # @api private
      def record_file(interview, tail = "")
        { "interviews/#{file_stem(interview.fetch(:reference))}.md" => record(interview) + tail }
      end

      # @api private
      def file_stem(reference) = reference.to_s.gsub(/[^A-Za-z0-9._-]/, "_")

      # @api private
      def bluebook(interview)
        name = interview.fetch(:subject)
        things = accepted(interview, :things)
        raise ArgumentError, "nothing was accepted: a draft needs at least one thing" if things.empty?

        out = ["Hecks.bluebook #{name.inspect} do"]
        out.concat(header(interview))
        out << %(  vision "TODO: say in one sentence what #{name} is for.")
        out << "  supporting" << ""
        out.concat(rule_lines(interview))
        out << fragment(interview).chomp << "end"
        "#{out.join("\n")}\n"
      end

      # The aggregates, with their commands: the part a later interview offers to merge.
      # @api private
      def fragment(interview)
        things = accepted(interview, :things).uniq { |t| word(t[:name]) }
        actions = accepted(interview, :actions)
        placed = things.map { |t| word(t[:name]) }
        blocks = things.map { |thing| aggregate(interview, thing, actions) }
        loose = actions.reject { |a| placed.include?(word(a[:thing])) }
        blocks << unplaced(interview, loose) unless loose.empty?
        "#{blocks.join("\n\n")}\n"
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
      def aggregate(interview, thing, actions)
        shape = shape_of(interview, thing, actions)
        lines = head_lines(interview, thing, shape)
        lines.concat(command_lines(interview, shape))
        lines.concat(InterviewShape.lifecycle(shape.steps, shape.creating, shape.rest))
        (lines << "  end").join("\n")
      end

      # What one accepted thing is made of: its fields, its actions, and its steps.
      # @api private
      def shape_of(interview, thing, actions)
        name = word(thing[:name])
        identifier = Naming.snake(word(thing[:identifier]))
        mine = InterviewShape.merged_actions(actions.select { |a| word(a[:thing]) == name })
        steps = accepted(interview, :transitions).select { |s| word(s[:thing]) == name }
        found = accepted(interview, :fields).select { |f| word(f[:thing]) == name }
        type = identifier_type(name, identifier)
        fields = InterviewShape.fields(found, name, identifier, type, lifecycle: !steps.empty?)
        creating = mine.select { |a| a[:creates] }
        Shape.new(name: name, identifier: identifier, type: type, fields: fields, steps: steps,
                  creating: creating, rest: mine - creating)
      end

      # The aggregate's opening: its identity, its fields, and the value object of each.
      # @api private
      def head_lines(interview, thing, shape)
        required = shape.creating.flat_map { |action| InterviewShape.takes(action) }
        ["  # #{source_note(interview, thing)}".rstrip,
         "  aggregate #{shape.name.inspect} do",
         "    description #{"TODO: describe what a #{shape.name} is.".inspect}", "",
         "    identified_by :#{shape.identifier}", "",
         "    attribute :#{shape.identifier}, #{shape.type}",
         *InterviewShape.attributes(shape.fields, required), "",
         "    value_object #{shape.type.inspect} do",
         "      attribute :value, String, pattern: #{PATTERN}", "    end",
         *InterviewShape.value_objects(shape.fields)]
      end

      # @api private
      def command_lines(interview, shape)
        creating = shape.creating.empty? ? [stub_create(shape.name)] : shape.creating
        creating.flat_map { |action| creating_command(interview, action, shape) } +
          shape.rest.flat_map { |action| mutating_command(interview, action, shape) }
      end

      # The creating command nothing in the interview named: a stub, marked for the developer.
      # @api private
      def stub_create(name) = { name: "Create", event: "#{name}Created", stub: true }

      # @api private
      def creating_command(interview, action, shape)
        verb = word(action[:name])
        note = action[:stub] ? STUB_NOTE : "    # #{source_note(interview, action)}"
        given, unknown = InterviewShape.inputs(action, shape.fields, shape.identifier)
        ["", note, "    command #{verb.inspect} do", "      goal #{"TODO: say what #{verb} does".inspect}",
         *InterviewShape.who_lines(action), "", "      attribute :#{shape.identifier}, #{shape.type}",
         *given.map { |f| "      attribute :#{f[:name]}, #{f[:type]}" }, *InterviewShape.unknown_lines(unknown), "",
         "      emits #{word(action[:event]).inspect}", "    end"]
      end

      # @api private
      def mutating_command(interview, action, shape)
        verb = word(action[:name])
        given, unknown = InterviewShape.inputs(action, shape.fields, shape.identifier)
        ["", "    # #{source_note(interview, action)}", "    command #{verb.inspect} do",
         "      goal #{"TODO: say what #{verb} does".inspect}", *InterviewShape.who_lines(action), "",
         "      reference_to #{shape.name}", *InterviewShape.input_lines(given), *InterviewShape.unknown_lines(unknown),
         *InterviewShape.assignment_lines(given), "", "      emits #{word(action[:event]).inspect}", "    end"]
      end

      # An action whose thing nobody accepted has nowhere to go; it is kept as a comment, not lost.
      # @api private
      def unplaced(interview, actions)
        lines = ["  # UNPLACED: these accepted actions name a thing that was not accepted. Place each, or drop it."]
        actions.each do |action|
          lines << "  #   - #{cite(interview, action)} #{word(action[:name])} on #{action[:thing]}, announcing #{action[:event]}"
        end
        lines.join("\n")
      end

      # @api private
      def identifier_type(name, field)
        type = Naming.pascal(field)
        type == name ? "#{type}Id" : type
      end

      # @api private
      def exchange_lines(exchange, number)
        lines = ["#{number}. **Q:** #{one_line(exchange[:question])}", "   **A:** #{one_line(exchange[:answer])}"]
        topic = exchange[:topic].to_s
        lines << "   _Topic: #{one_line(topic)}_" unless topic.empty?
        lines
      end

      # @api private
      def finding_lines(interview)
        lines = interview.fetch(:things).map do |f|
          "- Thing #{f[:number]}, #{f[:status]}: **#{f[:name]}**, identified by `#{f[:identifier]}` (exchange #{f[:source]})"
        end
        lines += interview.fetch(:actions).map { |f| action_line(f) }
        lines += interview.fetch(:fields, []).map do |f|
          values = f[:values].to_s.strip.empty? ? "" : ", one of #{f[:values]}"
          "- Field #{f[:number]}, #{f[:status]}: **#{f[:name]}** on #{f[:thing]}#{values} (exchange #{f[:source]})"
        end
        lines += interview.fetch(:transitions, []).map do |f|
          from = f[:from].to_s.strip.empty? ? "" : " from #{f[:from]}"
          "- Transition #{f[:number]}, #{f[:status]}: **#{f[:action]}** on #{f[:thing]} to #{f[:to]}#{from} " \
            "(exchange #{f[:source]})"
        end
        lines + interview.fetch(:rules).map do |f|
          "- Rule #{f[:number]}, #{f[:status]}: #{one_line(f[:statement])} (exchange #{f[:source]})"
        end
      end

      # @api private
      def action_line(finding)
        creates = finding[:creates] ? ", creates it" : ""
        takes = finding[:takes].to_s.strip.empty? ? "" : ", takes #{finding[:takes]}"
        by = finding[:by].to_s.strip.empty? ? "" : ", by #{finding[:by]}"
        "- Action #{finding[:number]}, #{finding[:status]}: **#{finding[:name]}** on #{finding[:thing]}, " \
          "announcing `#{finding[:event]}`#{creates}#{takes}#{by} (exchange #{finding[:source]})"
      end

      # @api private
      def accepted(interview, kind) = interview.fetch(kind, []).select { |finding| finding[:status] == ACCEPTED }

      # A free-text name as a PascalCase word safe to write into Ruby: `lend a book` is `LendABook`.
      # @api private
      def word(text) = text.to_s.split(/[^A-Za-z0-9]+/).reject(&:empty?).map { |part| part.sub(/\A./, &:upcase) }.join

      # @api private
      def one_line(text) = text.to_s.gsub(/\s+/, " ").strip

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
