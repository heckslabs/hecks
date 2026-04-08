module Hecks
  module EventStorm
    # Hecks::EventStorm::BluebookBuilder
    #
    # Builds a Structure::Domain from a Parser::ParseResult. Groups commands
    # under their aggregates, wires policies, attaches read models and external
    # systems, and validates that event names match command inferences.
    #
    # Part of the EventStorm module. Used by Hecks.from_event_storm to produce
    # the in-memory domain object.
    #
    #   result = EventStorm::Parser.new(source).parse
    #   domain = EventStorm::BluebookBuilder.new(result, name: "Ordering").build
    #
    class BluebookBuilder
      Structure = BluebookModel::Structure
      Behavior  = BluebookModel::Behavior

      # Initializes a BluebookBuilder from a parse result.
      #
      # @param parse_result [Parser::ParseResult] the intermediate representation
      #   produced by Parser or YamlParser, containing contexts, elements, and warnings
      # @param name [String, nil] optional domain name override; falls back to
      #   parse_result.domain_name, then "MyDomain"
      def initialize(parse_result, name: nil)
        @parse_result = parse_result
        @name = name || parse_result.domain_name || "MyDomain"
        @warnings = parse_result.warnings
      end

      # Builds the domain object from the parse result.
      #
      # Flattens all bounded context elements into a single list, groups them
      # by aggregate, validates event consistency, and constructs the Domain
      # with fully wired aggregates.
      #
      # @return [Structure::Domain] the built domain containing
      #   aggregates with commands, events, and policies
      def build
        # Flatten all context elements into a single aggregate list
        all_elements = @parse_result.contexts.flat_map(&:elements)
        aggregates = group_by_aggregate(all_elements)
        Structure::Domain.new(name: @name, aggregates: aggregates)
      end

      private

      # Groups parsed elements into aggregates with commands, events, and policies.
      #
      # Commands are assigned to their declared aggregate. Commands without an
      # aggregate are collected as "unassigned" and placed on the first aggregate.
      # Policies are assigned to the aggregate that owns their trigger command.
      # Events are inferred from command names.
      #
      # @param elements [Array<Parser::ParsedElement>] all elements from all contexts
      # @return [Array<Structure::Aggregate>] built aggregate objects
      def group_by_aggregate(elements)
        aggregate_commands = {}
        aggregate_policies = {}
        unassigned_commands = []

        elements.each do |el|
          case el.type
          when :command
            agg_name = el.meta[:aggregate]
            if agg_name
              aggregate_commands[agg_name] ||= []
              aggregate_commands[agg_name] << build_command(el)
            else
              unassigned_commands << build_command(el)
            end
          when :policy
            trigger = el.meta[:trigger]
            # Find which aggregate owns the trigger command
            agg_name = find_aggregate_for_trigger(elements, trigger)
            target = agg_name || "Default"
            aggregate_policies[target] ||= []
            aggregate_policies[target] << build_policy(el)
          end
        end

        validate_events(elements)

        all_agg_names = (aggregate_commands.keys + aggregate_policies.keys).uniq
        all_agg_names << "Default" unless unassigned_commands.empty? || all_agg_names.any?

        all_agg_names.map do |agg_name|
          commands = aggregate_commands.fetch(agg_name, [])
          commands += unassigned_commands if agg_name == all_agg_names.first && !unassigned_commands.empty?
          policies = aggregate_policies.fetch(agg_name, [])

          Structure::Aggregate.new(
            name: agg_name,
            commands: commands,
            events: infer_events(commands),
            policies: policies
          )
        end
      end

      # Constructs a Command domain object from a parsed element.
      #
      # Extracts read_models and external_systems from the element's metadata
      # and wraps them as domain model structures.
      #
      # @param element [Parser::ParsedElement] a parsed element with type :command
      # @return [Behavior::Command] the constructed command
      def build_command(element)
        read_models = (element.meta[:read_models] || []).map do |name|
          Structure::ReadModel.new(name: name)
        end
        externals = (element.meta[:external_systems] || []).map do |name|
          Structure::ExternalSystem.new(name: name)
        end

        Behavior::Command.new(
          name: element.name,
          read_models: read_models,
          external_systems: externals
        )
      end

      # Constructs a Policy domain object from a parsed element.
      #
      # @param element [Parser::ParsedElement] a parsed element with type :policy
      # @return [Behavior::Policy] the constructed policy with
      #   event_name and trigger_command set from metadata
      def build_policy(element)
        Behavior::Policy.new(
          name: element.name,
          event_name: element.meta[:event_name],
          trigger_command: element.meta[:trigger]
        )
      end

      # Finds the aggregate that owns a given trigger command name.
      #
      # Searches all elements for a command matching trigger_name and returns
      # its declared aggregate name, or nil if not found.
      #
      # @param elements [Array<Parser::ParsedElement>] all parsed elements
      # @param trigger_name [String] the command name to search for
      # @return [String, nil] the aggregate name, or nil if not found
      def find_aggregate_for_trigger(elements, trigger_name)
        elements.each do |el|
          next unless el.type == :command && el.name == trigger_name
          return el.meta[:aggregate] if el.meta[:aggregate]
        end
        nil
      end

      # Infers domain events from a list of commands.
      #
      # Each command produces one event whose name is derived from the command
      # name via Command#inferred_event_name (e.g., "PlaceOrder" -> "OrderPlaced").
      #
      # @param commands [Array<Behavior::Command>] commands to infer from
      # @return [Array<Behavior::BluebookEvent>] inferred events
      def infer_events(commands)
        commands.map do |cmd|
          Behavior::BluebookEvent.new(
            name: cmd.inferred_event_name,
            attributes: cmd.attributes
          )
        end
      end

      # Validates that event storm events match inferred events from commands.
      #
      # Compares explicitly declared event names from the storm against events
      # inferred from command names. Appends warnings for mismatches (case
      # differences or missing commands).
      #
      # @param elements [Array<Parser::ParsedElement>] all parsed elements
      # @return [void]
      def validate_events(elements)
        storm_events = elements.select { |e| e.type == :event }.map(&:name)
        commands = elements.select { |e| e.type == :command }

        inferred = {}
        commands.each do |cmd|
          dummy = Behavior::Command.new(name: cmd.name)
          inferred[dummy.inferred_event_name] = cmd.name
        end

        storm_events.each do |event_name|
          next if inferred.key?(event_name)

          close = inferred.keys.find { |k| k.downcase == event_name.downcase }
          if close
            @warnings << "Event '#{event_name}' doesn't match inferred '#{close}' from command '#{inferred[close]}' (case mismatch)"
          else
            @warnings << "Event '#{event_name}' has no matching command (expected a command that infers this event)"
          end
        end
      end
    end
  end
end
