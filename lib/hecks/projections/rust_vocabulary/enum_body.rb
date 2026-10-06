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
          "    fn render(&self, values: &[(&str, &str)]) -> String {",
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
           constants(enum, variants, spec[:kind]),
           rows.first.keys.map { |field| accessor(enum, field, variants, rows) },
           from_name(enum, spec[:kind]),
           extras(enum, variants, spec[:kind]),
           "}",
           ""]
        end

        # @param enum [String] the enum's name
        # @param variants [Array<String>] the variant names
        # @param kind [Symbol] `:order`, `:templates` or `:set`
        # @return [Array<String>] the `ORDER` or `ALL` constant, as Rust lines
        def constants(enum, variants, kind)
          list = variants.map { |variant| "        #{enum}::#{variant}," }
          if kind == :order
            ["    /// The declared step order, first to last.",
             "    pub const ORDER: [#{enum}; #{variants.size}] = [", list, "    ];", ""]
          else
            ["    /// Every row, in declared order.",
             "    pub const ALL: &'static [#{enum}] = &[", list, "    ];", ""]
          end
        end

        # @param enum [String] the enum's name
        # @param field [String] the row field the accessor reads
        # @param variants [Array<String>] the variant names
        # @param rows [Array<Hash>] the table's rows
        # @return [Array] the accessor, as Rust lines
        def accessor(enum, field, variants, rows)
          arms = variants.zip(rows).map do |variant, row|
            "            #{enum}::#{variant} => #{RustVocabulary.rust_string(row.fetch(field))},"
          end
          ["    /// The row's declared `#{field}`.",
           "    pub fn #{RustVocabulary.accessor_name(field)}(&self) -> &'static str {",
           "        match self {",
           arms,
           "        }",
           "    }",
           ""]
        end

        # Built on the enum's own list and name accessor, not a string match, so no wildcard arm.
        #
        # @param enum [String] the enum's name
        # @param kind [Symbol] `:order`, `:templates` or `:set`
        # @return [Array<String>] `from_name`, as Rust lines
        def from_name(enum, kind)
          list  = kind == :order ? "ORDER" : "ALL"
          field = kind == :templates ? "site" : RustVocabulary.name_field(kind)
          ["    /// The row whose `#{field}` is `name`, if any.",
           "    pub fn from_name(name: &str) -> Option<#{enum}> {",
           "        #{enum}::#{list}.iter().copied().find(|row| row.#{RustVocabulary.accessor_name(field)}() == name)",
           "    }",
           ""]
        end

        # @param enum [String] the enum's name
        # @param variants [Array<String>] the variant names
        # @param kind [Symbol] `:order`, `:templates` or `:set`
        # @return [Array<String>] the methods only this kind of table has, as Rust lines
        def extras(enum, variants, kind)
          case kind
          when :order then position_fn(enum, variants)
          when :templates then RENDER_FN
          else []
          end
        end

        # @param enum [String] the enum's name
        # @param variants [Array<String>] the variant names
        # @return [Array] `position`, as Rust lines
        def position_fn(enum, variants)
          arms = variants.each_with_index.map { |variant, index| "            #{enum}::#{variant} => #{index}," }
          ["    /// This step's index in `ORDER`.",
           "    pub fn position(&self) -> usize {",
           "        match self {",
           arms,
           "        }",
           "    }"]
        end
      end
    end
  end
end
