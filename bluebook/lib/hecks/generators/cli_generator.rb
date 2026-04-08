# Hecks::Generators::CliGenerator
#
# Generates Thor CLI subcommands from a Bluebook chapter definition.
# Walks the chapter's aggregates and their commands, emitting a Thor
# subcommand class where each command becomes a CLI verb with typed
# --flag options derived from the command's IR attributes.
#
# Works with ANY chapter -- not coupled to a specific domain.
#
#   domain = Hecks::Chapters::Bluebook.definition
#   gen = Hecks::Generators::CliGenerator.new(domain)
#   puts gen.generate
#
#   # Or generate and evaluate directly:
#   cli_class = gen.build_thor_class
#   cli_class.start(ARGV)
#
require_relative "cli_generator/type_mapper"

module Hecks
  module Generators
    class CliGenerator < Hecks::Generator
      # @param domain [Hecks::BluebookModel::Structure::Domain] chapter definition IR
      # @param namespace [String, nil] Ruby module to wrap the generated class in
      def initialize(domain, namespace: nil)
        @domain = domain
        @namespace = namespace
      end

      # Generates Ruby source code for a Thor subcommand class.
      #
      # @return [String] the generated Thor class source code
      def generate
        lines = []
        lines.concat(namespace_open)
        lines.concat(class_header)
        lines.concat(aggregate_commands)
        lines.concat(class_footer)
        lines.concat(namespace_close)
        lines.join("\n") + "\n"
      end

      # Builds a live Thor class by evaluating the generated source.
      # Useful for runtime CLI construction without writing files.
      #
      # @return [Class] a Thor subclass with all commands defined
      def build_thor_class
        require "thor"
        source = generate
        eval(source, TOPLEVEL_BINDING, "(#{class_name})") # rubocop:disable Security/Eval
        Object.const_get(class_name)
      end

      private

      def class_name
        "#{@domain.name}CLI"
      end

      def indent
        @namespace ? "  " : ""
      end

      def namespace_open
        return [] unless @namespace
        ["module #{@namespace}"]
      end

      def namespace_close
        return [] unless @namespace
        ["end"]
      end

      def class_header
        [
          "#{indent}class #{class_name} < Thor",
          "#{indent}  def self.exit_on_failure? = true",
          "",
        ]
      end

      def class_footer
        ["#{indent}end"]
      end

      def aggregate_commands
        lines = []
        aggregates_with_commands.each do |agg|
          agg.commands.each do |cmd|
            lines.concat(command_method(agg, cmd))
            lines << ""
          end
        end
        lines
      end

      def aggregates_with_commands
        @domain.aggregates.select { |a| a.commands.any? }
      end

      def command_method(aggregate, command)
        verb = unique_verb(aggregate, command)
        desc_text = command_description(aggregate, command)
        lines = []
        lines << "#{indent}  desc \"#{verb}\", \"#{desc_text}\""
        command.attributes.each do |attr|
          lines << option_line(attr)
        end
        lines << "#{indent}  def #{verb}"
        lines << "#{indent}    puts \"#{aggregate.name}##{command.name}(\#{options})\""
        lines << "#{indent}  end"
        lines
      end

      # Returns a unique CLI verb for each aggregate+command pair.
      # Prefixes with the aggregate name when the bare verb collides.
      # Appends a counter if prefixed verbs still collide.
      def unique_verb(aggregate, command)
        verb_map[object_id_for(aggregate, command)]
      end

      def object_id_for(agg, cmd)
        "#{agg.name}::#{cmd.name}"
      end

      def verb_map
        @verb_map ||= build_verb_map
      end

      def build_verb_map
        map = {}
        seen = Hash.new(0)
        aggregates_with_commands.each do |agg|
          agg.commands.each do |cmd|
            bare = Hecks::Utils.underscore(cmd.name)
            verb = bare_collision?(bare) ? prefixed_verb(agg, cmd) : bare
            if seen[verb] > 0
              verb = "#{verb}_#{seen[verb]}"
            end
            seen[verb] += 1
            map[object_id_for(agg, cmd)] = verb
          end
        end
        map
      end

      def prefixed_verb(aggregate, command)
        agg_prefix = Hecks::Utils.underscore(aggregate.name)
        cmd_verb = Hecks::Utils.underscore(command.name)
        "#{agg_prefix}_#{cmd_verb}"
      end

      def bare_collision?(verb)
        bare_counts[verb] > 1
      end

      def bare_counts
        @bare_counts ||= begin
          counts = Hash.new(0)
          aggregates_with_commands.each do |agg|
            agg.commands.each do |cmd|
              counts[Hecks::Utils.underscore(cmd.name)] += 1
            end
          end
          counts
        end
      end

      def command_description(aggregate, command)
        desc = command.description || aggregate.description
        desc ? desc.gsub('"', '\\"') : "Run #{command.name}"
      end

      def option_line(attr)
        thor_type = TypeMapper.thor_type(attr.type)
        "#{indent}  method_option :#{attr.name}, type: :#{thor_type}, desc: \"#{attr.name}\""
      end
    end
  end
end
