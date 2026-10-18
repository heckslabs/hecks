module Hecks
  module Projections
    module RustVocabulary
      # The `impl` block of one projected enum: its list constant, one accessor a row field,
      # `from_name`, and the extras a table's kind adds.
      module EnumBody
        # The private `render` a refusal-template enum carries, as Rust lines.
        RENDER_FN = [
          "    /// `RefusalWording.substitute`: replace every `{key}` marker, in the",
          "    /// order given. A template is read, never evaluated. Private: call",
          "    /// sites go through a site's typed `<Variant>Args::render_args`,",
          "    /// which formats and supplies every declared argument.",
          "    fn render(self, values: &[(&str, &str)]) -> String {",
          "        let mut text = self.template().to_string();",
          "        for (key, value) in values {",
          "            text = text.replace(&format!(\"{{{key}}}\"), value);",
          "        }",
          "        text",
          "    }"
        ].freeze

        module_function

        # @param spec [Hash] the table's entry in `RustVocabulary::TABLES`
        # @param variants [Array<String>] the variant names, in row order
        # @param rows [Array<Hash>] the table's rows
        # @return [Array] the lines of `impl <Enum> { ... }`, nested arrays allowed
        def impl_lines(spec, variants, rows)
          enum = spec[:enum]
          ["impl #{enum} {",
           constants(variants, spec[:kind]),
           rows.first.keys.map { |field| accessor(field, variants, rows) },
           from_name(spec[:kind]),
           extras(variants, spec[:kind]),
           "}",
           ""]
        end

        # @param variants [Array<String>] the variant names
        # @param kind [Symbol] `:order`, `:templates` or `:set`
        # @return [Array<String>] the `ORDER` or `ALL` constant, as Rust lines
        def constants(variants, kind)
          list = variants.map { |variant| "        Self::#{variant}," }
          if kind == :order
            ["    /// The declared step order, first to last.",
             "    pub const ORDER: [Self; #{variants.size}] = [", list, "    ];", ""]
          else
            ["    /// Every row, in declared order.",
             "    pub const ALL: &'static [Self] = &[", list, "    ];", ""]
          end
        end

        # @param field [String] the row field the accessor reads
        # @param variants [Array<String>] the variant names
        # @param rows [Array<Hash>] the table's rows
        # @return [Array] the accessor, as Rust lines
        def accessor(field, variants, rows)
          arms = variants.zip(rows).map do |variant, row|
            "            Self::#{variant} => #{RustVocabulary.rust_string(row.fetch(field))},"
          end
          ["    /// The row's declared `#{field}`.",
           "    pub const fn #{RustVocabulary.accessor_name(field)}(&self) -> &'static str {",
           "        match self {",
           arms,
           "        }",
           "    }",
           ""]
        end

        # Built on the enum's own list and name accessor, not a string match, so no wildcard arm.
        #
        # @param kind [Symbol] `:order`, `:templates` or `:set`
        # @return [Array<String>] `from_name`, as Rust lines
        def from_name(kind)
          list  = kind == :order ? "ORDER" : "ALL"
          field = kind == :templates ? "site" : RustVocabulary.name_field(kind)
          ["    /// The row whose `#{field}` is `name`, if any.",
           "    pub fn from_name(name: &str) -> Option<Self> {",
           "        Self::#{list}.iter().copied().find(|row| row.#{RustVocabulary.accessor_name(field)}() == name)",
           "    }",
           ""]
        end

        # @param variants [Array<String>] the variant names
        # @param kind [Symbol] `:order`, `:templates` or `:set`
        # @return [Array<String>] the methods only this kind of table has, as Rust lines
        def extras(variants, kind)
          case kind
          when :order then position_fn(variants)
          when :templates then RENDER_FN
          else []
          end
        end

        # @param variants [Array<String>] the variant names
        # @return [Array] `position`, as Rust lines
        def position_fn(variants)
          arms = variants.each_with_index.map { |variant, index| "            Self::#{variant} => #{index}," }
          ["    /// This step's index in `ORDER`.",
           "    pub const fn position(&self) -> usize {",
           "        match self {",
           arms,
           "        }",
           "    }"]
        end
      end
    end
  end
end
