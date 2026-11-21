# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # The Work items that landed, as the rework rate counts them: done, with the commit they
      # landed as. It selects and names; it counts nothing.
      module LandedWork
        module_function

        # @param records [Array] the Work records
        # @param field [#call] reads a field of a record
        # @return [Array<Hash>] `slug`, `title` and `epic` of each landed item
        def of(records, field)
          records.select { |record| landed?(record, field) }.map do |record|
            { slug: field.call(record, :work).to_s, title: field.call(record, :title).to_s, epic: field.call(record, :epic).to_s }
          end
        end

        def landed?(record, field)
          field.call(record, :status).to_s == "done" && !field.call(record, :landing).to_s.empty?
        end
      end
    end
  end
end
