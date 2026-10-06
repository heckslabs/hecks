require_relative "../naming"

module Hecks
  module CLI
    # What an interview's fields, command inputs and state changes become in a drafted aggregate
    # (ADR 0088): its attributes and their value objects, the fields a command is told, a note of
    # who does it, and the lifecycle.
    #
    # Pure, like `InterviewDraft`, which calls it: each method answers lines of bluebook text and
    # writes none. A name is written as `InterviewDraft.word` writes it.
    module InterviewShape
      module_function

      # The accepted fields of one thing, each with the type it will be written under. The
      # identifier is already a field, and a lifecycle owns `status`, so neither is repeated.
      #
      # @param found [Array<Hash>] the accepted field findings that name the thing
      # @param name [String] the thing's name, which no type may repeat
      # @param identifier [String] the identifying field, snake-cased
      # @param identifier_type [String] the type the identifier is written under
      # @param lifecycle [Boolean] whether the thing has a lifecycle
      # @return [Array<Hash>] each field's `name`, `type` and `values`
      def fields(found, name, identifier, identifier_type, lifecycle:)
        taken = [name, identifier_type]
        found.filter_map { |finding| field_row(finding, taken, identifier, lifecycle) }.uniq { |row| row[:name] }
      end

      # The attribute lines of the fields: required when the creating action takes one, else
      # optional.
      #
      # @param fields [Array<Hash>] the thing's fields, from `fields`
      # @param required [Array<String>] the field names the creating actions take
      # @return [Array<String>] one line per field
      def attributes(fields, required)
        fields.map do |field|
          suffix = required.include?(field[:name]) ? "" : ", optional: true"
          "    attribute :#{field[:name]}, #{field[:type]}#{suffix}"
        end
      end

      # The value object of each field, a blank line before each: a closed set when the expert
      # listed two or more values, and free text otherwise.
      #
      # @param fields [Array<Hash>] the thing's fields, from `fields`
      # @return [Array<String>] the lines
      def value_objects(fields)
        fields.flat_map do |field|
          rule = field[:values].size > 1 ? ", one_of: #{field[:values].inspect}" : ""
          ["", "    value_object #{field[:type].inspect} do", "      attribute :value, String#{rule}", "    end"]
        end
      end

      # The field names an action says it is told.
      #
      # @param action [Hash] an accepted action
      # @return [Array<String>] snake-cased field names
      def takes(action)
        action[:takes].to_s.split(/\s*,\s*/).map { |text| Naming.snake(InterviewDraft.word(text)) }.reject(&:empty?)
      end

      # What an action is told that the thing has as a field, and what it names that the thing
      # does not. The identifier is never counted: a command already carries it.
      #
      # @param action [Hash] an accepted action
      # @param fields [Array<Hash>] the thing's fields, from `fields`
      # @param identifier [String] the identifying field, snake-cased
      # @return [Array(Array<Hash>, Array<String>)] the fields it is told, and the names that have
      #   no field
      def inputs(action, fields, identifier)
        known, unknown = (takes(action) - [identifier]).partition { |text| fields.any? { |field| field[:name] == text } }
        [known.map { |text| fields.find { |field| field[:name] == text } }, unknown]
      end

      # @param inputs [Array<Hash>] the fields a command is told
      # @return [Array<String>] a blank line and an attribute line for each, or none
      def input_lines(inputs)
        inputs.empty? ? [] : ["", *inputs.map { |f| "      attribute :#{f[:name]}, #{f[:type]}" }]
      end

      # @param inputs [Array<Hash>] the fields a command is told
      # @return [Array<String>] a blank line and a `sets` line for each, or none
      def assignment_lines(inputs)
        inputs.empty? ? [] : ["", *inputs.map { |f| "      sets :#{f[:name]}" }]
      end

      # @param unknown [Array<String>] names an action is told that no accepted field has
      # @return [Array<String>] a note for each
      def unknown_lines(unknown)
        unknown.map { |text| "      # TODO: takes #{text}, but no accepted field of that name." }
      end

      # Who may do an action, as the expert said it. It is a note, not a role: a role is only
      # checked once the domain attaches Governance.
      #
      # @param action [Hash] an accepted action
      # @return [Array<String>] the note, or none
      def who_lines(action)
        by = action[:by].to_s.strip
        by.empty? ? [] : ["      # Who: #{by}. Declare it as a role once Governance is attached."]
      end

      # The lifecycle the accepted transitions describe. The state a creating action's step
      # leads to is where a thing starts; a step for an action the thing does not have is kept
      # as a comment.
      #
      # @param steps [Array<Hash>] the thing's accepted transitions
      # @param creating [Array<Hash>] the accepted actions that create it
      # @param rest [Array<Hash>] its other accepted actions
      # @return [Array<String>] the lines, or none when no step and start state can be placed
      def lifecycle(steps, creating, rest)
        starts, moves = steps.partition { |step| names_action?(creating, step) }
        placed, loose = moves.partition { |step| names_action?(rest, step) }
        placed = merged(placed)
        start = beginning(starts, placed)
        return [] if start.empty? || placed.empty?

        lifecycle_block(start, placed, loose)
      end

      # @api private
      def lifecycle_block(start, placed, loose)
        ["", "    lifecycle :status, default: #{start.inspect} do", *placed.map { |step| transition_line(step) },
         "    end", *loose.map { |step| loose_line(step) }]
      end

      # @api private
      def names_action?(actions, step)
        actions.map { |action| InterviewDraft.word(action[:name]) }.include?(InterviewDraft.word(step[:action]))
      end

      # One action for each name: an expert who refines an answer gets the same action accepted more
      # than once, and a command can be declared only once. The first one's event and place in the
      # interview stay; what each takes is joined, who does it is joined, and it creates if any did.
      #
      # @param actions [Array<Hash>] a thing's accepted actions
      # @return [Array<Hash>] the actions, with each name once and in the order first accepted
      def merged_actions(actions)
        actions.group_by { |action| InterviewDraft.word(action[:name]) }.values.map do |group|
          group.first.merge(creates: group.any? { |a| a[:creates] }, takes: joined(group, :takes, ", "),
                            by: joined(group, :by, " or "))
        end
      end

      # @api private
      def joined(group, key, separator)
        parts = group.flat_map { |a| a[key].to_s.split(separator == ", " ? /\s*,\s*/ : /\s+or\s+/) }
        parts.map(&:strip).reject(&:empty?).uniq.join(separator)
      end

      # @api private
      def field_row(finding, taken, identifier, lifecycle)
        field = Naming.snake(InterviewDraft.word(finding[:name]))
        return if field == identifier || (lifecycle && field == "status")

        type = Naming.pascal(field)
        type = "#{type}Value" while taken.include?(type)
        taken << type
        { name: field, type: type, values: finding[:values].to_s.split(/\s*,\s*|\s+or\s+/).map(&:strip).reject(&:empty?).uniq }
      end

      # One step for each action and state it leads to: the states it starts from are joined, and a
      # step with no state to start from means it may be taken from any.
      # @api private
      def merged(steps)
        steps.group_by { |step| [InterviewDraft.word(step[:action]), state_word(step[:to])] }.values.map do |group|
          froms = group.map { |step| step[:from].to_s.strip }
          group.first.merge(from: froms.any?(&:empty?) ? "" : froms.join(","))
        end
      end

      # The state a thing starts in: where its creating action's step leads, else the first state a
      # change is said to start from.
      # @api private
      def beginning(starts, placed)
        from = placed.map { |step| step[:from].to_s.split(",").first }.find { |text| !text.to_s.strip.empty? }
        state_word(starts.first&.fetch(:to) || from)
      end

      # @api private
      def transition_line(step)
        "      transition #{InterviewDraft.word(step[:action]).inspect} => #{state_word(step[:to]).inspect}" \
          "#{from_clause(step)}"
      end

      # @api private
      def loose_line(step)
        "    # UNPLACED transition: #{InterviewDraft.word(step[:action])} to #{state_word(step[:to])}; " \
          "no accepted action has that name."
      end

      # The states a step may start from: none, one, or several.
      # @api private
      def from_clause(step)
        states = step[:from].to_s.split(/\s*,\s*/).map { |text| state_word(text) }.reject(&:empty?)
        return "" if states.empty?

        states.one? ? ", from: #{states.first.inspect}" : ", from: %w[#{states.join(" ")}]"
      end

      # A state as a lowercase word: `Not Yet Triaged` is `not_yet_triaged`.
      # @api private
      def state_word(text) = text.to_s.strip.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_|_\z/, "")
    end
  end
end
