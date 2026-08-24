module Hecks
  module QuerySpecification
    module Common
      WhereClause = Struct.new(:field, :op, :value, keyword_init: true) do
        def to_h = { field: field.to_s, op: op.to_s, value: QuerySpecification.render_value(value) }
      end
    end
  end
end
