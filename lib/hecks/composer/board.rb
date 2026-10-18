module Hecks
  module Composer
    # The event-storming board of a chapter, on the hecksagon side: its aggregates with their
    # commands, the events each command emits, and the policies that make one event trigger another
    # command. It is read off the booted chapter, so it always shows what the text declares; the
    # board's own edits go through {BoardEdit}, which rewrites the text.
    module Board
      module_function

      # @param chapter [Bluebook::Chapter] the booted chapter
      # @param outline [Array<Hash>] the text outline (see {Outline}), which says where each note
      #   is declared
      # @return [Hash] `aggregates` (each with `name`, `at` and its `commands`, each command with
      #   `name`, `role`, `goal`, `emits` and `at`) and `policies` (`name`, `on`, `trigger`, `at`),
      #   where `at` is `{file:, line:}` or nil, and `on` and `trigger` read `Aggregate.Name`
      def call(chapter, outline:)
        places = Places.new(outline)
        { aggregates: chapter.aggregates.map { |aggregate| aggregate_note(aggregate, places) },
          policies:   chapter.policies.map { |policy| policy_note(policy, places) } }
      end

      # @api private
      def aggregate_note(aggregate, places)
        name = aggregate.hecks_name
        { name: name, at: places.of("aggregate", name),
          commands: aggregate.commands.map { |command| command_note(name, command, places) } }
      end

      # @api private
      def command_note(owner, command, places)
        name = command.hecks_name
        { name: name, role: command.role, goal: command.goal, emits: Array(command.emits).map(&:to_s),
          at: places.of("command", name, owner: owner) }
      end

      # @api private
      def policy_note(policy, places)
        { name: policy.name, on: policy.on_event, trigger: policy.trigger_command,
          at: places.of("policy", policy.name) }
      end

      # Where each declaration sits in the text, found by kind and name, and for a command by the
      # aggregate that holds it.
      class Places
        # @param outline [Array<Hash>] see {Outline}
        def initialize(outline)
          owner = nil
          @entries = outline.map do |entry|
            owner = entry[:name] if entry[:kind] == "aggregate"
            entry.merge(owner: entry[:kind] == "command" ? owner : nil)
          end
        end

        # @param kind [String] `aggregate`, `command` or `policy`
        # @param name [String] the declared name
        # @param owner [String, nil] the aggregate, for a command
        # @return [Hash, nil] `{file:, line:}` of the first match, or nil when the text has none
        def of(kind, name, owner: nil)
          found = @entries.find { |e| e[:kind] == kind && e[:name] == name && e[:owner] == owner }
          found && { file: found[:file], line: found[:line] }
        end
      end
    end
  end
end
