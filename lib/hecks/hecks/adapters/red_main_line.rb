# frozen_string_literal: true

require "hecks/runtime/asking"
require "hecks/runtime/row_sweep"

module Hecks
  module Adapters
    # The line `push_rehearsal.due` and the push train's report lead with while main is red: the
    # open `red-main-*` Work row, read from the booted Tickets domain and never written. Main being red
    # blocks promotion to stable, not a push, so this only says; nothing here refuses.
    module RedMainLine
      # The key every red-main row starts with; the rest is the failing CI run's id.
      PREFIX = "red-main-"

      module_function

      # @param registry [Runtime::Registry, nil] the booted registry; the asking one when nil
      # @return [String] the line and its line break, or "" when no red-main row is open or no
      #   registry is reachable
      def lead(registry = Runtime::Asking.registry)
        row = open_rows(registry).first
        row ? "#{plain(row[:detail])}; row #{row[:id]}\n" : ""
      end

      # @param field [Object] a row field, wrapped in a value or not
      # @return [Object] the field's plain value
      def plain(field) = field.respond_to?(:value) ? field.value : field

      # @param registry [Runtime::Registry, nil]
      # @return [Array<Hash>] the open (planned or started) red-main rows, oldest key first
      def open_rows(registry)
        return [] unless registry&.bluebook("Tickets")

        sweep = Runtime::RowSweep.new(registry)
        aggregate = sweep.query_aggregate("Tickets", "Work", verb: "Work.Undone")
        rows = sweep.rows("Tickets", aggregate, "Undone", {})
        rows.select { |row| row[:id].to_s.start_with?(PREFIX) }.sort_by { |row| row[:id].to_s }
      end
    end
  end
end
