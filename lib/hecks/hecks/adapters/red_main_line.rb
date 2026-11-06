# frozen_string_literal: true

require "hecks/runtime/asking"
require "hecks/runtime/row_sweep"
require_relative "red_main"

module Hecks
  module Adapters
    # What `push_rehearsal.due` and the push train's report lead with while main is red, and the red
    # Work rows the stop reads, from the booted Tickets domain and never written. The state itself is
    # {RedMain}'s; this says it in one line and lists the rows a fix may name.
    module RedMainLine
      # The key every red-main row starts with; the rest is the failing CI run's id.
      PREFIX = "red-main-"

      # The key every red row starts with: a push that fixes one goes out while main is red.
      RED = "red-"

      # How many open red rows a refusal names.
      LISTED = 5

      module_function

      # @param registry [Runtime::Registry, nil] the booted registry; the asking one when nil
      # @param checkout [String, nil] a directory inside the repository
      # @return [String] the STOP line while main is red, the unknown notice when `gh` cannot say,
      #   else "" (always "" when no registry is reachable or the world declares no stop)
      def lead(registry = Runtime::Asking.registry, checkout: nil)
        RedMain.state(registry, checkout: checkout).lead
      end

      # @param state [RedMain::State] a red state
      # @param registry [Runtime::Registry, nil]
      # @param fixes [String, nil] the row a boarding names, when it names an unknown one
      # @return [String] why a push that fixes no open red row is refused
      def refusal(state, registry, fixes: nil)
        run = state.run
        slugs = open_red_rows(registry).map { |row| row[:id].to_s }.first(LISTED)
        named = fixes ? "fixes=#{fixes} names no open red-* Work row; " : ""
        "main is red (CI run #{run.id} on #{run.sha[0, 9]}, #{run.failed_job}): #{named}only a push that fixes " \
          "a red row goes out; board again with fixes=<red row> (rows: #{slugs.empty? ? "none open" : slugs.join(", ")})"
      end

      # @return [Array<Hash>] the open (planned or started) rows whose key starts with `red-`
      def open_red_rows(registry) = undone_rows(registry).select { |row| row[:id].to_s.start_with?(RED) }

      # @param field [Object] a row field, wrapped in a value or not
      # @return [Object] the field's plain value
      def plain(field) = field.respond_to?(:value) ? field.value : field

      # @param registry [Runtime::Registry, nil]
      # @return [Array<Hash>] the open (planned or started) red-main rows, oldest key first
      def open_rows(registry) = undone_rows(registry).select { |row| row[:id].to_s.start_with?(PREFIX) }

      # @return [Array<Hash>] every open (planned or started) Work row, oldest key first
      def undone_rows(registry)
        return [] unless registry&.bluebook("Tickets")

        sweep = Runtime::RowSweep.new(registry)
        aggregate = sweep.query_aggregate("Tickets", "Work", verb: "Work.Undone")
        sweep.rows("Tickets", aggregate, "Undone", {}).sort_by { |row| row[:id].to_s }
      end
    end
  end
end
