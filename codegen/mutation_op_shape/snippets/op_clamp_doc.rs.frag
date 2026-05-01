                // i106 — bound the field to [min, max]. Value carries a
                // 2-element list literal; resolve_mutation_value returns
                // a Value::List which we read pairwise. Out-of-range
                // clamps to the boundary; in-range is a no-op.
