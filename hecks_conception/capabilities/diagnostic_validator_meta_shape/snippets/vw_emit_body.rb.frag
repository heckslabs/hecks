        rules = by_aggregate("WarningRule")
        [
          emit_header,
          emit_imports,
          rules.map { |r| emit_rule(r) }.join,
        ].join
