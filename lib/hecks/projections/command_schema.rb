require "json"
require_relative "../naming"
require_relative "../projector"
require_relative "command_schema/shape"

module Hecks
  module Projections
    # A JSON Schema (draft 2020-12) for every command's payload, projected from the bluebook's IR:
    # the facts a caller passes in `with:`. It is the cheap local check a client runs before it
    # asks the server, and the portable description of what a command takes.
    #
    # A schema cannot hold a rule over stored state, so the command's `given`s, `ensures` and
    # lifecycle `from:` ride along as `x-` annotations (their text, for display), and `x-role` names
    # who may run it. `Dispatcher#validate` stays the authority on those.
    #
    #     Projector.call(:command_schema, bluebook: bluebook)
    #     # => { "Banking/Account/Open.schema.json" => "{...}", ... }
    module CommandSchema
      extend Projector::Target

      projects_as :command_schema, emits: :files

      DIALECT = "https://json-schema.org/draft/2020-12/schema".freeze

      module_function

      # @param bluebook [Bluebook::Declaration] the bluebook being projected
      # @param options [Hash] unused
      # @return [Hash{String => String}] each command's schema file by path, entity commands too
      def call(bluebook:, options: {})
        bluebook.aggregates.each_with_object({}) do |aggregate, files|
          commands_of(aggregate, aggregate.hecks_name).each do |path, command|
            files["#{bluebook.name}/#{path}.schema.json"] = render(document(bluebook, aggregate, path, command))
          end
        end
      end

      # @return [String] the schema as indented JSON ending in a newline
      def render(schema) = "#{JSON.pretty_generate(schema)}\n"

      # One command's schema.
      #
      # @param bluebook [Bluebook::Declaration] the owning bluebook
      # @param aggregate [Bluebook::Aggregate] the aggregate that owns the command
      # @param path [String] `Aggregate/Command` or `Aggregate/Entity.Command`
      # @param command [Bluebook::Command] the command
      # @return [Hash{String => Object}] the schema
      def document(bluebook, aggregate, path, command)
        verb = "#{bluebook.name}::#{path.tr("/", ".")}"
        head = { "$schema" => DIALECT, "$id" => "#{bluebook.name}/#{path}", "title" => verb,
                 "description" => command.goal.to_s }.reject { |_, value| value.to_s.empty? }
        head.merge(Shape.object(command.attributes, aggregate)).merge(annotations(command, verb))
      end

      # @return [Array<Array(String, Bluebook::Command)>] each command of `aggregate` and its
      #   entities
      #   with its path, such as `["Account/Open", command]`
      def commands_of(aggregate, prefix)
        own = aggregate.commands.map { |command| ["#{prefix}/#{command.hecks_name}", command] }
        own + aggregate.entities.flat_map { |entity| commands_of(entity, "#{prefix}/#{entity.hecks_name}") }
      end

      # What a schema cannot validate, as text for a client to show: the rules over state, the role
      # and the events. Empty ones are left out.
      def annotations(command, verb)
        { "x-verb" => verb, "x-role" => command.role, "x-from" => command.from,
          "x-givens" => rules(command.givens), "x-ensures" => rules(command.ensures),
          "x-emits" => Array(command.emits).map(&:to_s) }.reject { |_, value| value.nil? || value == [] }
      end

      def rules(list) = list.map { |rule| { "description" => rule.description, "canonical" => rule.canonical } }
    end
  end
end
