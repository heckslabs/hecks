require_relative "../../runtime/refusal_wording"

module Hecks
  module Projections
    module RustVocabulary
      # The `#[cfg(test)]` module each projected enum file carries, as Rust lines.
      module Tests
        # The body of the placeholder test, after the line that opens its loop over the sites.
        PLACEHOLDER_BODY = [
          "            let template = site.template();",
          "            let mut keys: Vec<String> = Vec::new();",
          "            let mut current: Option<String> = None;",
          "            for ch in template.chars() {",
          "                match (ch, current.as_mut()) {",
          "                    ('{', _) => current = Some(String::new()),",
          "                    ('}', Some(key)) => {",
          "                        keys.push(key.clone());",
          "                        current = None;",
          "                    }",
          "                    (_, Some(key)) => key.push(ch),",
          "                    (_, None) => {}",
          "                }",
          "            }",
          "            let dummies: Vec<(String, String)> = keys.iter().map(|k| (k.clone(), format!(\"<{k}>\"))).collect();",
          "            let pairs: Vec<(&str, &str)> = dummies.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();",
          "            let rendered = site.render(&pairs);",
          "            assert!(",
          "                !rendered.contains('{') && !rendered.contains('}'),",
          "                \"{site:?} left an unrendered placeholder behind: {rendered:?}\"",
          "            );",
          "        }",
          "    }"
        ].freeze

        # Argument lists a refusal site's render test tries: empty, single and unsorted.
        LIST_CASES = [[], ["only \"one\""], %w[zeta alpha mid]].freeze

        module_function

        # @param enum [String] the enum's name
        # @param kind [Symbol] `:order`, `:templates` or `:set`
        # @param variants [Array<String>] the variant names
        # @param rows [Array<Hash>] the table's rows
        # @param by_site [Hash, nil] a template table's argument rows by site
        # @return [Array<String>] the test module, as Rust lines
        def tests(enum, kind, variants = [], rows = [], by_site = nil)
          lines = ["#[cfg(test)]", "mod tests {", "    use super::*;", ""] + kind_tests(enum, kind, variants, rows, by_site)
          lines.pop while lines.last == ""
          lines + ["}"]
        end

        # @return [Array<String>] the tests this kind of table has
        def kind_tests(enum, kind, variants, rows, by_site)
          return placeholder_test(enum) + [""] + render_args_test(variants, rows, by_site) if kind == :templates

          lines = name_test(enum, kind)
          kind == :order ? lines + order_test(enum) : lines
        end

        # @return [Array<String>] the test that every row is found by its own name
        def name_test(enum, kind)
          list = kind == :order ? "ORDER" : "ALL"
          name = RustVocabulary.accessor_name(RustVocabulary.name_field(kind))
          ["    #[test]",
           "    fn every_row_is_found_by_its_own_name() {",
           "        for row in #{enum}::#{list}.iter() {",
           "            assert_eq!(#{enum}::from_name(row.#{name}()), Some(*row));",
           "        }",
           "    }",
           ""]
        end

        # @return [Array<String>] the test that `position` is the index in `ORDER`
        def order_test(enum)
          ["    #[test]",
           "    fn position_is_the_index_in_order() {",
           "        for (index, step) in #{enum}::ORDER.iter().enumerate() {",
           "            assert_eq!(step.position(), index);",
           "        }",
           "    }",
           ""]
        end

        # Placeholders are read off each template's own text, never a second hand-kept list.
        #
        # @return [Array<String>] the test that no site renders a leftover placeholder
        def placeholder_test(enum)
          ["    #[test]",
           "    fn every_site_renders_with_no_leftover_placeholder() {",
           "        for site in #{enum}::ALL {"] + PLACEHOLDER_BODY
        end

        # Pins each site's typed `render_args` to Runtime::RefusalWording.render_with, computed
        # here, for empty, single and unsorted list arguments; scalars carry a `"` to compare
        # quoting.
        #
        # @return [Array<String>] the test that the Rust wording matches Ruby's
        def render_args_test(variants, rows, by_site)
          asserts = variants.zip(rows).flat_map do |variant, row|
            specs = by_site.fetch(Arguments.site_key(row))
            argument_cases(specs).map { |arguments| assertion(variant, row, specs, arguments) }
          end
          ["    #[test]",
           "    fn render_args_matches_ruby_render_site() {",
           asserts,
           "    }"].flatten
        end

        # @return [Array<String>] one `assert_eq!` of a variant's rendered arguments
        def assertion(variant, row, specs, arguments)
          expected = Runtime::RefusalWording.render_with(row.fetch("template"), specs, arguments)
          fields = specs.map do |spec|
            name = spec.fetch("argument")
            "#{Arguments.rust_field(name)}: #{rust_value(arguments.fetch(name.to_sym))}"
          end
          ["        assert_eq!(",
           "            #{variant}Args { #{fields.join(", ")} }.render_args(),",
           "            #{RustVocabulary.rust_string(expected)}",
           "        );"]
        end

        # @param value [String, Array<String>] an argument value
        # @return [String] the Rust expression for it
        def rust_value(value)
          return RustVocabulary.rust_string(value) unless value.is_a?(Array)

          "&[#{value.map { |item| RustVocabulary.rust_string(item) }.join(", ")}]"
        end

        # @param specs [Array<Hash>] a site's argument rows
        # @return [Array<Hash>] the argument values to try, by argument name
        def argument_cases(specs)
          cases = specs.any? { |spec| spec.fetch("shape") == "list" } ? LIST_CASES : [nil]
          cases.map do |items|
            specs.to_h do |spec|
              name = spec.fetch("argument")
              [name.to_sym, spec.fetch("shape") == "list" ? items : "#{name} \"x\""]
            end
          end
        end
      end
    end
  end
end
