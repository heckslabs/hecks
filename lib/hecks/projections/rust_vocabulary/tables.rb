module Hecks
  module Projections
    module RustVocabulary
      # Table name => enum name, variant-naming fields, file stem and kind.
      # `:order` adds `position`; `:templates` adds `render` and the typed `<Variant>Args`.
      TABLES = {
        "RefusalTemplate"        => { enum: "RefusalSite",     variant_from: %w[refusal site], file: "refusal_template",
                                      kind: :templates, arguments: "RefusalSiteArgument" },
        "QueryComparator"        => { enum: "QueryComparator", variant_from: %w[name], file: "query_comparator", kind: :set },
        "FieldHint"              => { enum: "FieldHint",       variant_from: %w[name], file: "field_hint", kind: :set },
        "RefusalClass"           => { enum: "RefusalClass",    variant_from: %w[name], file: "refusal_class", kind: :set },
        "Reducer"                => { enum: "Reducer",         variant_from: %w[name], file: "reducer", kind: :set },
        "AggregateDispatchOrder" => { enum: "AggregateStep",   variant_from: %w[step], file: "aggregate_dispatch_order",
                                      kind: :order },
        "EntityDispatchOrder"    => { enum: "EntityStep",      variant_from: %w[step], file: "entity_dispatch_order",
                                      kind: :order }
      }.freeze
    end
  end
end
