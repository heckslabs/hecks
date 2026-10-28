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
        # @param fields [Hash{Symbol => Class, Array<Class>}] the fields a row may carry, by class
        # @param required [Array<Symbol>] the fields a row must carry
        # @param defaults [Hash{Symbol => Object}] what a field takes when the row omits it
        # @param many [Boolean] whether the project may declare more than one row
        def initialize(object, fields:, required: [], defaults: {}, many: false)
          @object = object
          @fields = fields
          @required = required
          @defaults = defaults
          @many = many
          @renamed = {}
        end

        # Reads a row that still spells a retired field name as the field that replaced it, saying
        # so on standard error (ADR 0134).
        #
        # @param renamed [Hash{Symbol => Symbol}] a retired field name to the one that replaced it
        # @return [RootRows] self
        def renaming(renamed)
          @renamed = renamed
          self
        end

        # @param bluebook [Bluebook::Declaration] the bluebook that declares the route table
        # @return [Array<Hash{Symbol => Object}>] each checked row, defaults filled; empty when the
        #   bluebook declares none
        # @raise [Table::Invalid] when a row is refused
        def read(chapter)
          members = members_of(chapter)
          problems = []
          problems << "a project declares one #{@object} row, not #{members.size}" if members.size > 1 && !@many
          rows = members.each_with_index.map { |member, index| check(member, index, problems) }
          return rows if problems.empty?

          raise Table::Invalid, "the #{@object} rows are refused:\n#{problems.map { |line| "  - #{line}" }.join("\n")}"
        end

        private

        # The rows the bluebook declares in the value object, with retired field names respelled.
        def members_of(chapter) = Table.rows_of(chapter, @object).map { |member| respell(member) }

        # The row with each retired name respelled, unless it already carries the new one.
        def respell(member)
          retired = @renamed.select { |old, new| member.key?(old) && !member.key?(new) }
          retired.each { |old, new| warn "hecks: the #{@object} row field #{old} is deprecated, use #{new}" }
          member.transform_keys { |key| retired.fetch(key, key) }
        end

        def check(member, index, problems)
          label = "#{@object} row #{index + 1}"
          check_fields(member, label, problems)
          @defaults.merge(typed_fields(member, label, problems))
        end

        def check_fields(member, label, problems)
          unknown = member.keys - @fields.keys
          problems << "#{label} has no field #{unknown.join(", ")}; fields are #{@fields.keys.join(", ")}" if unknown.any?
          (@required - member.keys).each { |field| problems << "#{label} needs #{field}" }
        end

        # A field of the wrong class is recorded as a problem and kept, so the row still reads.
        def typed_fields(member, label, problems)
          member.slice(*@fields.keys).select do |field, value|
            kinds = Array(@fields.fetch(field))
            kinds.any? { |kind| value.is_a?(kind) } ||
              (problems << "#{label} has #{field} #{value.inspect}; it is a #{kinds.join(" or ")}")
          end
        end
      end
    end
  end
end
