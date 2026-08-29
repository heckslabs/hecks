require_relative "../common/options"

module Hecks
  module QuerySpecification
    module ReadModel
      # The read-model-specific specification: Common::Options' shared
      # query attributes plus `joins`, the one thing a read model
      # declares that a plain Query does not.
      class Specification < Common::Options
        attr_reader :joins

        def initialize(joins: [], **)
          super(**)
          @joins = joins
        end

        def to_h = options_to_h.merge(joins: @joins)
      end
    end
  end
end
