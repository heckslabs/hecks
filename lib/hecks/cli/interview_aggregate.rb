require_relative "../naming"
require_relative "interview_shape"

module Hecks
  module CLI
    # The bluebook text of one accepted thing: its aggregate, with its value objects, commands and
    # lifecycle. `InterviewDraft` extends it, and supplies the naming and citing helpers it calls.
    module InterviewAggregate
      # The pattern every generated string field carries: it refuses a blank value.
      PATTERN = %q('[^ \t\n\r]').freeze

      # What stands in for a creating command nothing in the interview named.
      STUB_NOTE = "    # TODO: no action that creates was accepted; replace Create with the real one.".freeze

      # One accepted thing: what it is called and identified by, its fields, its transitions, the
      # actions that create it and the others.
      Shape = Struct.new(:name, :identifier, :type, :fields, :steps, :creating, :rest, keyword_init: true)
      private_constant :PATTERN, :STUB_NOTE, :Shape

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
        type = identifier_type(name, identifier)
        steps = of_thing(accepted(interview, :transitions), name)
        mine = InterviewShape.merged_actions(of_thing(actions, name))
        creating = mine.select { |a| a[:creates] }
        Shape.new(name: name, identifier: identifier, type: type, steps: steps, creating: creating,
                  fields: shape_fields(interview, [name, identifier, type], steps), rest: mine - creating)
      end

      # @api private
      def shape_fields(interview, identity, steps)
        name, identifier, type = identity
        InterviewShape.fields(of_thing(accepted(interview, :fields), name), name, identifier, type,
                              lifecycle: !steps.empty?)
      end

      # @api private
      def of_thing(findings, name) = findings.select { |finding| word(finding[:thing]) == name }

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
         *type_lines(shape)]
      end

      # The value object that types the identifier, then the value object of each field.
      # @api private
      def type_lines(shape)
        ["    value_object #{shape.type.inspect} do",
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
        note = action[:stub] ? STUB_NOTE : "    # #{source_note(interview, action)}"
        given, unknown = InterviewShape.inputs(action, shape.fields, shape.identifier)
        command_open(action, note) +
          ["      attribute :#{shape.identifier}, #{shape.type}",
           *given.map { |f| "      attribute :#{f[:name]}, #{f[:type]}" }, *InterviewShape.unknown_lines(unknown), ""] +
          command_close(action)
      end

      # @api private
      def mutating_command(interview, action, shape)
        given, unknown = InterviewShape.inputs(action, shape.fields, shape.identifier)
        command_open(action, "    # #{source_note(interview, action)}") +
          ["      reference_to #{shape.name}", *InterviewShape.input_lines(given), *InterviewShape.unknown_lines(unknown),
           *InterviewShape.assignment_lines(given), ""] +
          command_close(action)
      end

      # The lines every command opens with: a blank, its source note, its name, its goal and
      # who may run it.
      # @api private
      def command_open(action, note)
        verb = word(action[:name])
        ["", note, "    command #{verb.inspect} do", "      goal #{"TODO: say what #{verb} does".inspect}",
         *InterviewShape.who_lines(action), ""]
      end

      # @api private
      def command_close(action) = ["      emits #{word(action[:event]).inspect}", "    end"]

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
    end
  end
end
