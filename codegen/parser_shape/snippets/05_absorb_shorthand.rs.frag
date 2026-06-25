fn absorb_shorthand(line: &str, agg: &mut Aggregate) {
    match parse_shorthand(line) {
        ShorthandResult::Attribute(a) => agg.attributes.push(a),
        ShorthandResult::Reference(r) => agg.references.push(r),
        ShorthandResult::None => {}
    }
}

