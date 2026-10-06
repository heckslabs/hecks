# frozen_string_literal: true

require_relative "table"

module Hecks
  module Projections
    module Site
      # Reads and checks the rows a project declares beside its route table for the files at the
      # project's root, one row object at a time: the fields it may carry, the Ruby class each
      # takes, which are required and what the others default to.
      #
      # A row that is refused raises `Table::Invalid` naming every problem, so a project sees all of
      # them at once.
      class RootRows
        # @param object [String] the value object the rows are declared in
        # @param fields [Hash{Symbol => Class}] the fields a row may carry, with the class each
        #   takes
        # @param required [Array<Symbol>] the fields a row must carry
        # @param defaults [Hash{Symbol => Object}] what a field takes when the row omits it
        # @param many [Boolean] whether the project may declare more than one row
        def initialize(object, fields:, required: [], defaults: {}, many: false)
          @object = object
          @fields = fields
          @required = required
          @defaults = defaults
          @many = many
        end

        # @param chapter [Bluebook::Chapter] the chapter that declares the route table
        # @return [Array<Hash{Symbol => Object}>] each checked row, defaults filled; empty when the
        #   chapter declares none
        # @raise [Table::Invalid] when a row is refused
        def read(chapter)
          members = Table.rows_of(chapter, @object)
          problems = []
          problems << "a project declares one #{@object} row, not #{members.size}" if members.size > 1 && !@many
          rows = members.each_with_index.map { |member, index| check(member, index, problems) }
          return rows if problems.empty?

          raise Table::Invalid, "the #{@object} rows are refused:\n#{problems.map { |line| "  - #{line}" }.join("\n")}"
        end

        private

        def check(member, index, problems)
          label = "#{@object} row #{index + 1}"
          unknown = member.keys - @fields.keys
          problems << "#{label} has no field #{unknown.join(', ')}; fields are #{@fields.keys.join(', ')}" if unknown.any?
          (@required - member.keys).each { |field| problems << "#{label} needs #{field}" }
          typed = member.slice(*@fields.keys).select do |field, value|
            kind = @fields.fetch(field)
            value.is_a?(kind) || (problems << "#{label} has #{field} #{value.inspect}; it is a #{kind}")
          end
          @defaults.merge(typed)
        end
      end
    end
  end
end
