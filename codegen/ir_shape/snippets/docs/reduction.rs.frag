/// A scalar reduction over a query's matched record set — the aggregation
/// half of the query DSL grown up (deciderate Layer 0a). `Count` needs no
/// field ; `Sum`/`Max`/`Min`/`Median` fold the named numeric field. Applied
/// after where/order_by/limit ; when the Query also carries `group_by`, the
/// reduction is computed per partition instead of over the whole set. The
/// winning *record* (argmax) stays expressible as `order_by + limit 1` ;
/// `Max` here is the scalar maximum VALUE of the field.
