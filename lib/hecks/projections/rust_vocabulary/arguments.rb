require_relative "../../runtime/refusal_wording"
require_relative "arguments/support"

module Hecks
  module Projections
    module RustVocabulary
      # The typed `<Variant>Args` structs of a refusal-template enum: each site's declared arguments
      # checked against its template, then written as Rust.
      module Arguments
        module_function

        # [refusal, site] => that site's argument rows; refused unless they name exactly the
        # template's placeholders, in first-appearance order, with known formatting rules.
        #
        # @param rows [Array<Hash>] the RefusalTemplate rows
        # @param argument_rows [Array<Hash>] the RefusalSiteArgument rows
        # @return [Hash{Array<String> => Array<Hash>}] each site's argument rows
        # @raise [ArgumentError] when an argument names no template or disagrees with one
        def site_arguments(rows, argument_rows)
          grouped = argument_rows.group_by { |row| site_key(row) }
          orphans = grouped.keys - rows.map { |row| site_key(row) }
          raise ArgumentError, "RefusalSiteArgument rows name no RefusalTemplate: #{orphans.inspect}" if orphans.any?

          rows.to_h { |row| [site_key(row), site_specs(row, grouped)] }
        end

        # @param row [Hash] a RefusalTemplate or RefusalSiteArgument row
        # @return [Array<String>] its refusal and site
        def site_key(row) = [row.fetch("refusal"), row.fetch("site")]

        # @param row [Hash] a RefusalTemplate row
        # @param grouped [Hash] the argument rows by site
        # @return [Array<Hash>] the site's argument rows, once checked against the template
        # @raise [ArgumentError] when they do not match the template's placeholders
        def site_specs(row, grouped)
          key   = site_key(row)
          specs = grouped.fetch(key, [])
          wants = row.fetch("template").scan(/\{(\w+)\}/).flatten.uniq
          names = specs.map { |spec| spec.fetch("argument") }
          unless names == wants
            raise ArgumentError, "RefusalSiteArgument for #{key.join("/")} declares #{names.inspect}; " \
                                 "its template's placeholders are #{wants.inspect}"
          end
          specs.each { |spec| check_rule!(key, spec) }
        end

        # @param key [Array<String>] the site's refusal and site
        # @param spec [Hash] one argument row
        # @return [void]
        # @raise [ArgumentError] when the row's shape, quoting or sorting is unknown
        def check_rule!(key, spec)
          where = "#{key.join("/")}.#{spec.fetch("argument")}"
          unless Runtime::RefusalWording::SHAPES.include?(spec.fetch("shape"))
            raise ArgumentError, "#{where}: unknown shape #{spec["shape"].inspect}"
          end
          unless Runtime::RefusalWording::QUOTINGS.include?(spec.fetch("quoting"))
            raise ArgumentError, "#{where}: unknown quoting #{spec["quoting"].inspect}"
          end
          return if %w[true false].include?(spec.fetch("sorted"))

          raise ArgumentError, "#{where}: sorted must be \"true\" or \"false\""
        end

        # @param enum [String] the enum's name
        # @param variants [Array<String>] the variant names
        # @param rows [Array<Hash>] the RefusalTemplate rows
        # @param by_site [Hash] the argument rows by site
        # @return [Array] the support functions and one args struct a variant, as Rust lines
        def argument_types(enum, variants, rows, by_site)
          SUPPORT + variants.zip(rows).flat_map do |variant, row|
            args_struct(enum, variant, row, by_site.fetch(site_key(row)))
          end
        end

        # @param enum [String] the enum's name
        # @param variant [String] the variant's name
        # @param row [Hash] the variant's RefusalTemplate row
        # @param specs [Array<Hash>] the variant's argument rows
        # @return [Array] its `<Variant>Args` struct and `render_args`, as Rust lines
        def args_struct(enum, variant, row, specs)
          struct_lines(enum, variant, row, specs) + impl_lines(enum, variant, specs)
        end

        # @return [Array] the struct holding a variant's arguments, as Rust lines
        def struct_lines(enum, variant, row, specs)
          [struct_doc(enum, variant, row),
           "#[derive(Debug, Clone, Copy)]",
           "pub struct #{variant}Args<'a> {",
           struct_fields(specs),
           "}",
           ""]
        end

        # @return [Array] the `render_args` that formats each argument and fills the template
        def impl_lines(enum, variant, specs)
          ["impl #{variant}Args<'_> {",
           "    /// The site's wording, every argument formatted by its declared row.",
           "    pub fn render_args(&self) -> String {",
           render_body(enum, variant, specs),
           "    }",
           "}",
           ""]
        end

        # @return [Array<String>] the formatting `let`s and the `render` call
        def render_body(enum, variant, specs)
          locals = specs.filter_map { |spec| formatted_local(spec) }
          [locals.map { |line| "        #{line}" },
           "        #{enum}::#{variant}.render(&[",
           render_pairs(specs),
           "        ])"]
        end

        # @return [String] the doc comment above a variant's args struct
        def struct_doc(enum, variant, row)
          "/// `#{enum}::#{variant}`'s arguments — `RefusalWording.render_site(" \
            "#{RustVocabulary.rust_string(row.fetch("refusal"))}, #{RustVocabulary.rust_string(row.fetch("site"))}, ...)`."
        end

        # @return [Array<String>] a doc line and a field for each argument
        def struct_fields(specs)
          specs.flat_map do |spec|
            type = spec.fetch("shape") == "list" ? "&'a [&'a str]" : "&'a str"
            ["    /// #{rule_reading(spec)}", "    pub #{rust_field(spec.fetch("argument"))}: #{type},"]
          end
        end

        # @return [Array<String>] the `(name, value)` pair each argument adds to `render`
        def render_pairs(specs)
          specs.map do |spec|
            name  = spec.fetch("argument")
            value = formatted_local(spec) ? "#{local_name(name)}.as_str()" : "self.#{rust_field(name)}"
            "            (#{RustVocabulary.rust_string(name)}, #{value}),"
          end
        end

        # @param spec [Hash] one argument row
        # @return [String, nil] the `let` that formats it, or nil when it is used as it stands
        def formatted_local(spec)
          name  = spec.fetch("argument")
          field = "self.#{rust_field(name)}"
          if spec.fetch("shape") == "list"
            "let #{local_name(name)} = list(#{field}, #{spec.fetch("sorted")}, #{spec.fetch("quoting") == "inspect"}, " \
              "#{RustVocabulary.rust_string(spec.fetch("separator"))}, " \
              "#{RustVocabulary.rust_string(spec.fetch("when_empty"))});"
          elsif spec.fetch("quoting") == "inspect"
            "let #{local_name(name)} = quoted(#{field});"
          end
        end

        # @param spec [Hash] one argument row
        # @return [String] how the row formats its argument, in words
        def rule_reading(spec)
          quoting = spec.fetch("quoting") == "inspect" ? ", quoted" : ""
          return "scalar#{quoting}" unless spec.fetch("shape") == "list"

          sorted = spec.fetch("sorted") == "true" ? ", sorted" : ""
          "list#{sorted}#{quoting}, joined #{spec.fetch("separator").inspect}, empty reads #{spec.fetch("when_empty").inspect}"
        end

        # @param argument [String] an argument's name
        # @return [String] the Rust local that holds its formatted text
        def local_name(argument) = "#{argument}_text"

        # @param argument [String] an argument's name
        # @return [String] the Rust field, raw-escaped when the name is a keyword
        def rust_field(argument) = RustVocabulary::RUST_KEYWORDS.include?(argument) ? "r##{argument}" : argument
      end
    end
  end
end
