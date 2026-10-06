module Hecks
  module Projections
    module RustVocabulary
      module Arguments
        # The free functions every `<Variant>Args::render_args` formats through, as Rust lines.
        SUPPORT = [
          "/// Ruby's `#inspect` of a name, as a refusal quotes it: `{:?}` on a",
          "/// `&str`, the quoting every kernel call site used before",
          "/// RefusalSiteArgument existed.",
          "fn quoted(text: &str) -> String {",
          "    format!(\"{text:?}\")",
          "}",
          "",
          "/// A list argument, written the way its RefusalSiteArgument row says:",
          "/// sorted first (before quoting), each item quoted, then joined; an",
          "/// empty list reads `when_empty`.",
          "fn list(items: &[&str], sorted: bool, inspect: bool, separator: &str, when_empty: &str) -> String {",
          "    let mut items = items.to_vec();",
          "    if sorted {",
          "        items.sort_unstable();",
          "    }",
          "    if items.is_empty() {",
          "        return when_empty.to_string();",
          "    }",
          "    let write = |item: &&str| if inspect { quoted(item) } else { item.to_string() };",
          "    items.iter().map(write).collect::<Vec<_>>().join(separator)",
          "}",
          ""
        ].freeze
      end
    end
  end
end
