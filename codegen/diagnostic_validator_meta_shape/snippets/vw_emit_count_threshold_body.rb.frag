        a = rule["attrs"]
        threshold = a["threshold"].to_i
        doc = "Returns Some(msg) if the domain has more than #{threshold} aggregates."
        <<~RS
          /// #{doc}
          pub fn #{a["rust_fn_name"]}(domain: &Domain) -> Option<String> {
              if domain.aggregates.len() > #{threshold} {
                  Some(format!(
                      "#{a["message_template"]}",
                      domain.name,
                      domain.aggregates.len()
                  ))
              } else {
                  None
              }
          }

        RS
