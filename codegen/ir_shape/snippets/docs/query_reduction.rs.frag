    /// Optional scalar reduction. `count` / `sum :field` / `max :field` /
    /// `min :field` / `median :field` collapse the post-filter/order/limit
    /// record set to ONE scalar over a field (count needs no field). Applied
    /// after limit ; when group_by is also present the reduction is computed
    /// per partition. (deciderate Layer 0a — the aggregation half of the
    /// query DSL grown up.)
