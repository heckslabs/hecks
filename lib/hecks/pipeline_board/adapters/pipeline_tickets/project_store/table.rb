# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    module PipelineBoard
      class ProjectStore
        # One table of a project's Tickets store, read row by row with the columns the board needs.
        # The SQLite adapter keeps a value object as JSON (`{"value": ...}`) and a list as a JSON
        # array; each cell is read back to the plain value, so a row reads as a record of the
        # aggregate does.
        module Table
          module_function

          # @param db [SQLite3::Database] the open, read-only store
          # @param name [String] the table, such as `"work"`
          # @param needed [Array<String>] the columns the board cannot do without
          # @param wanted [Array<String>] the columns it reads when the table has them
          # @return [Array<Hash{Symbol => Object}>, nil] the rows, nil when the table is missing
          # @raise [Unavailable] when the table lacks a needed column
          def rows(db, name, needed:, wanted: [])
            held = columns(db, name)
            return nil if held.empty?

            missing = needed - held
            raise Unavailable, "the #{name} table has no #{missing.join(", ")} column" unless missing.empty?

            selected(db, name, needed + (wanted & held))
          end

          # @return [Array<Hash{Symbol => Object}>] each row's named columns, read back plain
          def selected(db, name, read)
            keys = read.map(&:to_sym)
            db.execute("SELECT #{read.map { |column| %("#{column}") }.join(", ")} FROM \"#{name}\"")
              .map { |row| keys.zip(row.map { |cell| plain(cell) }).to_h }
          end

          # @return [Array<String>] the table's columns; none when there is no such table
          def columns(db, name) = db.execute("PRAGMA table_info(\"#{name}\")").map { |info| info[1] }

          # @param cell [Object] a stored cell
          # @return [Object] the cell's plain value: a value object's `value`, a list's elements
          def plain(cell)
            return cell unless cell.is_a?(String) && cell.start_with?("{", "[")

            unwrapped(JSON.parse(cell))
          rescue JSON::ParserError
            cell
          end

          # A value object is read back to its value; a list keeps each element as a value
          # object (`{value: ...}`), as a record's list of words holds them.
          def unwrapped(value)
            return value.map { |element| element.is_a?(Hash) ? element.transform_keys(&:to_sym) : element } if value.is_a?(Array)
            return value["value"] if value.is_a?(Hash) && value.key?("value")

            value
          end
        end
      end
    end
  end
end
