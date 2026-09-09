module Hecks
  module QuerySpecification
    module Common
      # `target` — see `WhereClause`'s own header (ADR 0055): which
      # many-side `include`d aggregate this `limit` applies to, on a
      # `read_model` declaring more than one. `nil` for a plain `Query`,
      # and for a `read_model` with a single many-side head.
      LimitSpec = Struct.new(:value, :target, keyword_init: true) do
        def to_h
          base = { value: QuerySpecification.render_value(value) }
          target ? base.merge(target: target.to_s) : base
        end
      end
    end
  end
end
