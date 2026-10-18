require_relative "board_edit/command_text"
require_relative "board_edit/source"

module Hecks
  module Composer
    # What the board does to the text, on the hecksagon side: each action on a note is one exact
    # edit of the bluebook, with no model in the loop, so a board change is instant and the text
    # stays the single source of truth. It answers the patched file; the editor applies it as an
    # ordinary edit, so Undo takes it back.
    #
    # Fields, rules and givens are not on the board: they stay in the text, where the agent can
    # fill them in.
    module BoardEdit
      # Raised when an action cannot be carried out, in the board's own words.
      class Refused < StandardError; end

      NAME = /\A[A-Z][A-Za-z0-9]*\z/
      DOTTED = /\A([A-Z][A-Za-z0-9]*)\.([A-Z][A-Za-z0-9]*)\z/

      # Each action and the arguments it takes.
      OPERATIONS = {
        "add_aggregate" => %i[name], "add_command" => %i[aggregate name event],
        "add_event" => %i[aggregate command name], "add_policy" => %i[name on trigger],
        "delete" => %i[kind name aggregate], "delete_event" => %i[aggregate command name]
      }.freeze

      module_function

      # @param stage [String] a staged directory holding the workspace as it is on screen
      # @param action [String] one of the keys of `OPERATIONS`
      # @param args [Hash{String => String}] the action's arguments
      # @return [Hash] the patched file: `path`, its whole new `text`, and the `line` to show
      # @raise [Refused] if the action is unknown or cannot be carried out
      def call(stage:, action:, args:)
        wanted = OPERATIONS.fetch(action) { raise Refused, "the board has no action called #{action.inspect}" }
        values = wanted.to_h { |key| [key, args[key.to_s].to_s.strip] }
        public_send(action, Source.new(stage), **values)
      end

      # @api private
      def add_aggregate(source, name:)
        named!(name, "an aggregate")
        refuse!("#{name} is already an aggregate") if source.places.of("aggregate", name)
        header = source.chapter
        source.insert(header[:file], source.block_end(header), aggregate_lines(name))
      end

      # A new aggregate is known by a key of its own, so its first command can create it.
      # @api private
      def aggregate_lines(name)
        ["", "  aggregate \"#{name}\" do", "    description \"Describe #{name}.\"", "",
         "    attribute :key, #{name}Key", "    identified_by :key", "",
         "    value_object \"#{name}Key\" do", "      attribute :value, String", "    end", "  end"]
      end

      # @api private
      def add_command(source, aggregate:, name:, event:)
        named!(name, "a command")
        named!(event, "an event") unless event.empty?
        where = aggregate_at(source, aggregate)
        refuse!("#{aggregate} already has a command #{name}") if source.places.of("command", name, owner: aggregate)
        close = source.block_end(where)
        block = source.slice(where[:file], where[:line], close)
        lines = CommandText.lines(block: block, indent: source.indent(where), aggregate: aggregate, name: name, event: event)
        source.insert(where[:file], close, lines)
      end

      # @api private
      def add_event(source, aggregate:, command:, name:)
        named!(name, "an event")
        where = command_at(source, aggregate, command)
        refuse!("#{command} already emits #{name}") if emit_line(source, where, name)
        pad = " " * (source.indent(where) + 2)
        source.insert(where[:file], source.block_end(where), ["#{pad}emits #{name}"])
      end

      # @api private
      def add_policy(source, name:, on:, trigger:)
        named!(name, "a policy")
        refuse!("there is already a policy #{name}") if source.places.of("policy", name)
        event = dotted!(on, "the event")
        target = dotted!(trigger, "the command")
        command_at(source, target[1], target[2])
        header = source.chapter
        source.insert(header[:file], source.block_end(header), policy_lines(name, event, target))
      end

      # @api private
      def policy_lines(name, event, target)
        ["", "  policy \"#{name}\" do", "    on #{event[1]}::#{event[2]}", "    trigger #{target[1]}::#{target[2]}", "  end"]
      end

      # @api private
      def delete(source, kind:, name:, aggregate:)
        where = case kind
                when "aggregate" then aggregate_at(source, name)
                when "command" then command_at(source, aggregate, name)
                when "policy" then source.places.of("policy", name) || refuse!("there is no policy #{name}")
                else refuse!("the board cannot delete a #{kind.inspect}")
                end
        source.remove(where[:file], where[:line] - 1, source.block_end(where))
      end

      # @api private
      def delete_event(source, aggregate:, command:, name:)
        where = command_at(source, aggregate, command)
        line = emit_line(source, where, name) or refuse!("#{command} does not emit #{name}")
        source.remove(where[:file], line, line)
      end

      # @api private
      def aggregate_at(source, name)
        source.places.of("aggregate", name) || refuse!("there is no aggregate #{name}")
      end

      # @api private
      def command_at(source, aggregate, name)
        source.places.of("command", name, owner: aggregate) || refuse!("#{aggregate} has no command #{name}")
      end

      # The 0-based index of the line in a command's block that emits the event, or nil.
      # @api private
      def emit_line(source, where, name)
        from = where[:line]
        block = source.slice(where[:file], from, source.block_end(where))
        found = block.index { |text| text.match?(/\A\s*emits\s+("?)#{Regexp.escape(name)}\1\s*\z/) }
        found && (from + found)
      end

      # @api private
      def dotted!(text, what)
        DOTTED.match(text) || refuse!("#{what} is written Aggregate.Name, not #{text.inspect}")
      end

      # @api private
      def named!(name, what)
        refuse!("#{what} needs a name that starts with a capital letter, with letters and digits only") unless NAME.match?(name)
      end

      # @api private
      def refuse!(message) = raise(Refused, message)
    end
  end
end
