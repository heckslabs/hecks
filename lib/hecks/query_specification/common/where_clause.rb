module Hecks
  module QuerySpecification
    module Common
      # One filter clause. `target` names the many-side `include`d aggregate on a
      # `read_model` with several (ADR 0055); `to_h` omits it when `nil`.
      WhereClause = Struct.new(:field, :op, :value, :target, keyword_init: true) do
        def to_h
          base = { field: field.to_s, op: op.to_s, value: QuerySpecification.render_value(value) }
          target ? base.merge(target: target.to_s) : base
        end
      end
    end
  end
end
