# frozen_string_literal: true

require "hecks"
require_relative "../boot_lock"
require_relative "../probe"

module Hecks
  module Adapters
    module PipelineBoard
      # The Tickets bluebook's `Work.Undone`, applied to Work items read from a store that is not
      # booted. The `where` clauses and the `order_by` are read from the query as the bluebook
      # declares it, so another project's board leaves out exactly what the Hecks board does.
      class UndoneRule
        # The Tickets bluebook beside the board, described when the registry holds none.
        BLUEBOOK_DIR = File.expand_path("../../../tickets/bluebook", __dir__)

        # @param registry [Runtime::Registry, nil] a registry whose Tickets bluebook is read
        def initialize(registry: nil)
          @registry = registry
        end

        # @param items [Array<Hash{Symbol => Object}>] Work items, plain
        # @return [Array<Hash>] those the query's clauses hold for, in its order
        def apply(items)
          kept = items.select { |item| query.wheres.all? { |clause| holds?(clause, item) } }
          field = order_field
          field ? kept.sort_by { |item| item[field].to_s.rjust(12, "0") } : kept
        end

        private

        # @return [Symbol, nil] the field the query orders by
        def order_field = field_of(query.order_by)

        def field_of(ordered) = ordered&.field&.to_sym

        def holds?(clause, item)
          actual = item[clause.field.to_sym].to_s
          case clause.op.to_s
          when "in" then listed(clause.value).include?(actual)
          when "eq" then clause.value.to_s == actual
          else raise Unavailable, "Work.Undone compares with #{clause.op}, which the board cannot read"
          end
        end

        # @return [Array<String>] the words of an `in` clause's comma-separated list
        def listed(value) = value.to_s.split(",").map(&:strip)

        def query = (@query ||= work.queries.find { |declared| declared.name == "Undone" })

        def work = bluebook.aggregates.find { |aggregate| aggregate.hecks_name == "Work" }

        def bluebook
          held = @registry.respond_to?(:bluebooks) ? @registry.bluebooks["Tickets"] : nil
          held || BootLock.exclusive(wait: BootLock::WAIT_SECONDS) { Hecks.describe(BLUEBOOK_DIR).registry }
                          .bluebooks.fetch("Tickets")
        end
      end
    end
  end
end
