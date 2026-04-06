# Hecks::GrammarRegistryMethods
#
# Grammar registration and lookup. A grammar is a modeling vocabulary
# (BlueBook for DDD, GameBook for ECS, etc.) that provides DSL methods,
# IR nodes, and a parser for the workshop.
#
#   Hecks.register_grammar(:bluebook) do |g|
#     g.parser = BlueBook::Grammar
#     g.builder = Hecks::DSL::DomainBuilder
#     g.entry_point = :domain
#   end
#
#   Hecks.grammar(:bluebook).parser.parse("Pizza.create")
#
module Hecks
  class GrammarDescriptor
    attr_accessor :parser, :builder, :entry_point,
                  :bare_commands, :handle_methods, :type_map

    def initialize(name)
      @name = name
      @entry_point = :domain
      @bare_commands = []
      @handle_methods = []
      @type_map = {}
    end

    attr_reader :name
  end

  module GrammarRegistryMethods
    def grammar_registry
      @grammar_registry ||= {}
    end

    def register_grammar(name)
      desc = GrammarDescriptor.new(name)
      yield desc if block_given?
      grammar_registry[name.to_sym] = desc
    end

    def grammar(name = :bluebook)
      grammar_desc = grammar_registry[name.to_sym]
      return grammar_desc if grammar_desc
      # Auto-register BlueBook on first access if available
      if name.to_sym == :bluebook && defined?(BlueBook)
        BlueBook.register!
        grammar_registry[:bluebook]
      end
    end

    def grammars
      grammar_registry.keys
    end
  end
end
