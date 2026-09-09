module Hecks
  module QuerySpecification
    module Common
      # `target` — which many-side `include`d aggregate this clause applies
      # to on a `read_model` with more than one (ADR 0055's own `on:`,
      # `ReadModelBuilder#where_impl`). Always `nil` for a plain `Query`'s
      # own `where` (that builder never overrides `where_impl` to accept
      # `on:`), and `nil` for a `read_model` with a single many-side head,
      # where naming one is unnecessary. `to_h` omits the key entirely
      # rather than emitting `target: nil` — the same "absent, not null"
      # convention `count`/`median_field` already established
      # (`lib/hecks/bluebook/read_model.rb`), so every read model that
      # never uses `on:` keeps its existing wire shape byte-identical.
      WhereClause = Struct.new(:field, :op, :value, :target, keyword_init: true) do
        def to_h
          base = { field: field.to_s, op: op.to_s, value: QuerySpecification.render_value(value) }
          target ? base.merge(target: target.to_s) : base
        end
      end
    end
  end
end
