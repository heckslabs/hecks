require_relative "../projector"
require_relative "../runtime/refusal_wording"
require_relative "vocabulary"

module Hecks
  module Projections
    # The language's closed sets, projected into the Rust kernel — one
    # `rust/src/kernel/vocab/<table>.rs` per Vocabulary table, each a
    # `pub enum` plus `match`-based accessors with no wildcard arm, so a
    # row the chapter gains is a compile error at every exhaustive match
    # over it rather than a silent gap.
    #
    #   Projector.call(:rust_vocabulary, bluebook: <the Bluebook chapter>)
    #   # => { "vocab/mod.rs" => "...", "vocab/refusal_template.rs" => "...", ... }
    #
    # Paths are relative to rust/src/kernel/; bin/project_rust_vocabulary
    # writes them. This generalizes the old bin/project_refusal_wording,
    # which read Runtime::RefusalWording::TEMPLATES — a hand-typed copy of
    # the RefusalTemplate rows. This reads the chapter itself.
    #
    # ## Only `TABLES` the kernel needs
    #
    # Each entry in `TABLES` names its enum and its generated extras; a
    # table not listed is not projected. The enum names that differ from
    # the table name keep existing Rust call sites (`RefusalSite`) and the
    # dispatch-step names D1 consumes (`AggregateStep`, `EntityStep`).
    #
    # ## Typed refusal arguments
    #
    # The templates table also reads RefusalSiteArgument: every site gets a
    # `<Variant>Args` struct whose fields are exactly the site's declared
    # arguments (a `&str` per scalar, a `&[&str]` per list) and a
    # `render_args` that formats each one by its row. `render` itself stays
    # private to the generated module, so no call site can pass an argument
    # list by hand — leaving one out does not compile. The generated test
    # pins every site's `render_args` output (empty, single and multiple
    # unsorted lists) against Runtime::RefusalWording.render_with, computed
    # here in Ruby.
    module RustVocabulary
      extend Projector::Target

      projects_as :rust_vocabulary, declares: "Vocabulary", emits: :files

      GENERATOR = "bin/project_rust_vocabulary".freeze
      SOURCE    = "lib/hecks/language/bluebook/vocabulary.bluebook".freeze

      # table name => enum name, variant-naming fields, file stem, kind.
      # `:order` tables also get `ORDER` and `position`; `:templates`
      # gets `render`, the typed `<Variant>Args` (read off the `arguments`
      # table) and the placeholder and argument-rendering tests.
      TABLES = {
        "RefusalTemplate"        => { enum: "RefusalSite",     variant_from: %w[refusal site], file: "refusal_template",
                                      kind: :templates, arguments: "RefusalSiteArgument" },
        "QueryComparator"        => { enum: "QueryComparator", variant_from: %w[name], file: "query_comparator", kind: :set },
        "FieldHint"              => { enum: "FieldHint",       variant_from: %w[name], file: "field_hint", kind: :set },
        "AggregateDispatchOrder" => { enum: "AggregateStep",   variant_from: %w[step], file: "aggregate_dispatch_order",
                                      kind: :order },
        "EntityDispatchOrder"    => { enum: "EntityStep",      variant_from: %w[step], file: "entity_dispatch_order",
                                      kind: :order }
      }.freeze

      RUST_KEYWORDS = %w[as async await break const continue crate dyn else enum extern false fn for if impl in let loop
                         match mod move mut pub ref return self static struct super trait true type unsafe use where
                         while abstract become box do final macro override priv typeof unsized virtual yield try].freeze

      module_function

      # The projector protocol.
      #
      # @param bluebook [Bluebook::Behaviour::Chapter] the chapter declaring the
      #   Vocabulary aggregate to project
      # @param options [Hash] unused; accepted to satisfy the registry's call shape
      # @return [Hash{String => String}] each generated file's path, relative to
      #   `rust/src/kernel/`, mapped to its full Rust source
      def call(bluebook:, options: {}) = render(bluebook)

      # Renders every file `TABLES` projects: `vocab/mod.rs` plus one `.rs` file
      # per table, each an exhaustive enum with accessors and a pinned test module.
      #
      # @param bluebook [Bluebook::Behaviour::Chapter] the chapter declaring the
      #   Vocabulary aggregate to render
      # @return [Hash{String => String}] each generated file's path, relative to
      #   `rust/src/kernel/`, mapped to its full Rust source
      # @raise [ArgumentError] if `bluebook` does not declare a `TABLES`-named table,
      #   or the `:arguments` table a `:templates` entry names
      def render(bluebook)
        tables = Vocabulary.tables(bluebook)
        files = TABLES.to_h do |table, spec|
          rows = tables.fetch(table) { raise ArgumentError, "Vocabulary declares no #{table} table" }
          arguments = spec[:arguments] && tables.fetch(spec[:arguments]) do
            raise ArgumentError, "Vocabulary declares no #{spec[:arguments]} table"
          end
          ["vocab/#{spec[:file]}.rs", table_file(table, spec, rows, arguments)]
        end
        { "vocab/mod.rs" => mod_file }.merge(files)
      end

      # The generated-file banner every projected file opens with.
      #
      # @param table [String] the Vocabulary table name being projected, such as
      #   `"RefusalTemplate"`
      # @return [String] the banner, as Rust line comments
      def header(table)
        <<~RUST
          // GENERATED by #{GENERATOR} (Hecks::Projections::RustVocabulary,
          // lib/hecks/projections/rust_vocabulary.rb) from Vocabulary::#{table}
          // (#{SOURCE}).
          // Do not hand-edit — re-run #{GENERATOR} instead.
        RUST
      end

      # Renders `vocab/mod.rs`, the entry point that re-exports every projected enum.
      #
      # @return [String] `vocab/mod.rs`'s full source: one `pub mod` and `pub use`
      #   per entry in `TABLES`
      def mod_file
        mods    = TABLES.values.map { |spec| "pub mod #{spec[:file]};" }.join("\n")
        exports = TABLES.values.map { |spec| "pub use #{spec[:file]}::#{spec[:enum]};" }.join("\n")
        <<~RUST
          // GENERATED by #{GENERATOR} (Hecks::Projections::RustVocabulary,
          // lib/hecks/projections/rust_vocabulary.rb) from the Vocabulary
          // aggregate (#{SOURCE}).
          // Do not hand-edit — re-run #{GENERATOR} instead.
          //
          // One module per projected table. Every enum below is matched
          // exhaustively by its own accessors — no wildcard arm — so a row the
          // language gains fails to compile until it is handled.

          #{mods}

          #{exports}
        RUST
      end

      # One table's full `.rs` source: its exhaustive enum, per-field accessors,
      # `from_name`, its `:order`/`:templates` extras, and its `#[cfg(test)]` module.
      #
      # @param table [String] the Vocabulary table name, such as `"RefusalTemplate"`
      # @param spec [Hash] the table's `TABLES` entry (`:enum`, `:variant_from`,
      #   `:file`, `:kind`, and, for `:templates`, `:arguments`)
      # @param rows [Array<Hash{String => String}>] the table's rows, as read off
      #   the chapter by `Vocabulary.tables`
      # @param argument_rows [Array<Hash{String => String}>, nil] the
      #   `RefusalSiteArgument` rows, only when `spec[:kind] == :templates`
      # @return [String] the table's full `.rs` file source
      # @raise [ArgumentError] if two rows would generate the same enum variant name
      def table_file(table, spec, rows, argument_rows = nil)
        variants = rows.map { |row| variant_name(row, spec[:variant_from]) }
        duplicates = variants.tally.select { |_, count| count > 1 }.keys
        raise ArgumentError, "duplicate #{spec[:enum]} variant(s): #{duplicates.join(', ')}" if duplicates.any?

        enum   = spec[:enum]
        fields = rows.first.keys
        by_site = spec[:kind] == :templates ? site_arguments(rows, argument_rows) : nil
        body = [
          header(table),
          "#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]",
          "pub enum #{enum} {",
          variants.map { |variant| "    #{variant}," },
          "}",
          "",
          "impl #{enum} {",
          constants(enum, variants, spec[:kind]),
          fields.map { |field| accessor(enum, field, variants, rows) },
          from_name(enum, spec[:kind]),
          extras(enum, variants, spec[:kind]),
          "}",
          "",
          by_site ? argument_types(enum, variants, rows, by_site) : [],
          tests(enum, spec[:kind], variants, rows, by_site)
        ]
        "#{body.flatten.join("\n").rstrip}\n"
      end

      # Renders the enum's declared-order constant: `ORDER` for `:order`, `ALL` otherwise.
      #
      # @param enum [String] the Rust enum name, such as `"RefusalSite"`
      # @param variants [Array<String>] each row's generated variant name, in
      #   declared order
      # @param kind [Symbol] the table's `:kind` (`:order`, `:templates`, or `:set`)
      # @return [Array<String>] the lines declaring the enum's `ORDER` constant
      #   (`:order`) or `ALL` constant (otherwise)
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

      # Renders one field's `pub fn` accessor, an exhaustive match over every variant.
      #
      # @param enum [String] the Rust enum name
      # @param field [String] the row field this accessor reads, such as `"name"`
      # @param variants [Array<String>] each row's generated variant name, in
      #   declared order, matching `rows`
      # @param rows [Array<Hash{String => String}>] the table's rows, in the same
      #   order as `variants`
      # @return [Array<String>] the lines for the field's `pub fn` accessor, one
      #   match arm per variant
      def accessor(enum, field, variants, rows)
        arms = variants.zip(rows).map { |variant, row| "            #{enum}::#{variant} => #{rust_string(row.fetch(field))}," }
        ["    /// The row's declared `#{field}`.",
         "    pub fn #{accessor_name(field)}(&self) -> &'static str {",
         "        match self {",
         arms,
         "        }",
         "    }",
         ""]
      end

      # Built on the enum's own list and name accessor, not a string
      # match, so it needs no wildcard arm either.
      #
      # @param enum [String] the Rust enum name
      # @param kind [Symbol] the table's `:kind` (`:order`, `:templates`, or `:set`)
      # @return [Array<String>] the lines for the enum's `from_name` associated function
      def from_name(enum, kind)
        list  = kind == :order ? "ORDER" : "ALL"
        field = kind == :templates ? "site" : name_field(kind)
        ["    /// The row whose `#{field}` is `name`, if any.",
         "    pub fn from_name(name: &str) -> Option<#{enum}> {",
         "        #{enum}::#{list}.iter().copied().find(|row| row.#{accessor_name(field)}() == name)",
         "    }",
         ""]
      end

      # Renders the extra methods a table's `:kind` adds beyond the shared accessors.
      #
      # @param enum [String] the Rust enum name
      # @param variants [Array<String>] each row's generated variant name, in
      #   declared order
      # @param kind [Symbol] the table's `:kind` (`:order`, `:templates`, or `:set`)
      # @return [Array<String>] `:order`'s `position` method, `:templates`'s private
      #   `render` method, or `[]` for `:set`
      def extras(enum, variants, kind)
        case kind
        when :order
          arms = variants.each_with_index.map { |variant, index| "            #{enum}::#{variant} => #{index}," }
          ["    /// This step's index in `ORDER`.",
           "    pub fn position(&self) -> usize {",
           "        match self {",
           arms,
           "        }",
           "    }"]
        when :templates
          ["    /// `RefusalWording.substitute`: replace every `{key}` marker, in the",
           "    /// order given. A template is read, never evaluated. Private: call",
           "    /// sites go through a site's typed `<Variant>Args::render_args`,",
           "    /// which formats and supplies every declared argument.",
           "    fn render(&self, values: &[(&str, &str)]) -> String {",
           "        let mut text = self.template().to_string();",
           "        for (key, value) in values {",
           "            text = text.replace(&format!(\"{{{key}}}\"), value);",
           "        }",
           "        text",
           "    }"]
        else
          []
        end
      end

      # [refusal, site] => that site's argument rows, in declared order —
      # refused unless they name exactly the template's own placeholders,
      # in the order each first appears, with only known formatting rules.
      #
      # @param rows [Array<Hash{String => String}>] the `RefusalTemplate` rows,
      #   in declared order
      # @param argument_rows [Array<Hash{String => String}>] the `RefusalSiteArgument`
      #   rows for every site
      # @return [Hash{Array<String> => Array<Hash{String => String}>}] each
      #   `[refusal, site]` pair mapped to its declared argument rows, in declared order
      # @raise [ArgumentError] if an argument row names a `refusal`/`site` no
      #   `RefusalTemplate` row declares, if a site's declared arguments do not match
      #   its template's `{placeholder}`s in order, or if `check_rule!` rejects a
      #   row's `"shape"`, `"quoting"`, or `"sorted"` value
      def site_arguments(rows, argument_rows)
        grouped = argument_rows.group_by { |row| [row.fetch("refusal"), row.fetch("site")] }
        orphans = grouped.keys - rows.map { |row| [row.fetch("refusal"), row.fetch("site")] }
        raise ArgumentError, "RefusalSiteArgument rows name no RefusalTemplate: #{orphans.inspect}" if orphans.any?

        rows.to_h do |row|
          key   = [row.fetch("refusal"), row.fetch("site")]
          specs = grouped.fetch(key, [])
          wants = row.fetch("template").scan(/\{(\w+)\}/).flatten.uniq
          names = specs.map { |spec| spec.fetch("argument") }
          unless names == wants
            raise ArgumentError, "RefusalSiteArgument for #{key.join('/')} declares #{names.inspect}; " \
                                 "its template's placeholders are #{wants.inspect}"
          end
          specs.each { |spec| check_rule!(key, spec) }
          [key, specs]
        end
      end

      # Refuses a `RefusalSiteArgument` row whose formatting fields are not
      # recognized rules.
      #
      # @param key [Array<String>] the `[refusal, site]` pair `spec` belongs to,
      #   used in the raised message
      # @param spec [Hash{String => String}] one `RefusalSiteArgument` row
      #   (`"shape"`, `"quoting"`, `"sorted"`)
      # @return [void]
      # @raise [ArgumentError] if `spec`'s `"shape"` is not in
      #   `Runtime::RefusalWording::SHAPES`, its `"quoting"` is not in
      #   `Runtime::RefusalWording::QUOTINGS`, or its `"sorted"` is not
      #   `"true"`/`"false"`
      def check_rule!(key, spec)
        where = "#{key.join('/')}.#{spec.fetch('argument')}"
        unless Runtime::RefusalWording::SHAPES.include?(spec.fetch("shape"))
          raise ArgumentError, "#{where}: unknown shape #{spec['shape'].inspect}"
        end
        unless Runtime::RefusalWording::QUOTINGS.include?(spec.fetch("quoting"))
          raise ArgumentError, "#{where}: unknown quoting #{spec['quoting'].inspect}"
        end
        return if %w[true false].include?(spec.fetch("sorted"))

        raise ArgumentError, "#{where}: sorted must be \"true\" or \"false\""
      end

      # Renders every `:templates` variant's typed argument struct, plus the two
      # helper functions (`quoted`, `list`) they share.
      #
      # @param enum [String] the Rust enum name
      # @param variants [Array<String>] each row's generated variant name, matching `rows`
      # @param rows [Array<Hash{String => String}>] the `RefusalTemplate` rows, in
      #   the same order as `variants`
      # @param by_site [Hash{Array<String> => Array<Hash{String => String}>}] each
      #   `[refusal, site]` pair's declared argument rows, as built by `site_arguments`
      # @return [Array<String>] the shared `quoted`/`list` helper functions, followed
      #   by every variant's `<Variant>Args` struct and `render_args` implementation
      def argument_types(enum, variants, rows, by_site)
        support = [
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
        ]
        support + variants.zip(rows).flat_map do |variant, row|
          args_struct(enum, variant, row, by_site.fetch([row.fetch("refusal"), row.fetch("site")]))
        end
      end

      # Renders one variant's `<Variant>Args` struct and its `render_args` method.
      #
      # @param enum [String] the Rust enum name
      # @param variant [String] the row's generated variant name
      # @param row [Hash{String => String}] the `RefusalTemplate` row this variant projects
      # @param specs [Array<Hash{String => String}>] the variant's declared
      #   `RefusalSiteArgument` rows, in declared order
      # @return [Array<String>] the lines for the variant's `<Variant>Args` struct
      #   and its `render_args` method
      def args_struct(enum, variant, row, specs)
        fields = specs.flat_map do |spec|
          type = spec.fetch("shape") == "list" ? "&'a [&'a str]" : "&'a str"
          ["    /// #{rule_reading(spec)}", "    pub #{rust_field(spec.fetch('argument'))}: #{type},"]
        end
        locals = specs.filter_map { |spec| formatted_local(spec) }
        pairs  = specs.map do |spec|
          name  = spec.fetch("argument")
          value = formatted_local(spec) ? "#{local_name(name)}.as_str()" : "self.#{rust_field(name)}"
          "            (#{rust_string(name)}, #{value}),"
        end
        ["/// `#{enum}::#{variant}`'s arguments — `RefusalWording.render_site(" \
         "#{rust_string(row.fetch('refusal'))}, #{rust_string(row.fetch('site'))}, ...)`.",
         "#[derive(Debug, Clone, Copy)]",
         "pub struct #{variant}Args<'a> {",
         fields,
         "}",
         "",
         "impl #{variant}Args<'_> {",
         "    /// The site's wording, every argument formatted by its declared row.",
         "    pub fn render_args(&self) -> String {",
         locals.map { |line| "        #{line}" },
         "        #{enum}::#{variant}.render(&[",
         pairs,
         "        ])",
         "    }",
         "}",
         ""]
      end

      # The `let` binding, if any, `args_struct` inserts before a variant's
      # `render_args` computes its argument pairs.
      #
      # @param spec [Hash{String => String}] one `RefusalSiteArgument` row
      #   (`"argument"`, `"shape"`, `"quoting"`, and, for a list, `"sorted"`,
      #   `"separator"`, `"when_empty"`)
      # @return [String, nil] the `let` line formatting the argument through
      #   `list`/`quoted`, or `nil` if the argument needs no formatting local
      #   (a scalar written as-is)
      def formatted_local(spec)
        name  = spec.fetch("argument")
        field = "self.#{rust_field(name)}"
        if spec.fetch("shape") == "list"
          "let #{local_name(name)} = list(#{field}, #{spec.fetch('sorted')}, #{spec.fetch('quoting') == 'inspect'}, " \
            "#{rust_string(spec.fetch('separator'))}, #{rust_string(spec.fetch('when_empty'))});"
        elsif spec.fetch("quoting") == "inspect"
          "let #{local_name(name)} = quoted(#{field});"
        end
      end

      # Describes one argument's formatting rule in English, for its struct field's doc comment.
      #
      # @param spec [Hash{String => String}] one `RefusalSiteArgument` row
      #   (`"shape"`, `"quoting"`, and, for a list, `"sorted"`, `"separator"`,
      #   `"when_empty"`)
      # @return [String] a short English reading of the row's formatting rule,
      #   used as the struct field's own doc comment
      def rule_reading(spec)
        quoting = spec.fetch("quoting") == "inspect" ? ", quoted" : ""
        return "scalar#{quoting}" unless spec.fetch("shape") == "list"

        sorted = spec.fetch("sorted") == "true" ? ", sorted" : ""
        "list#{sorted}#{quoting}, joined #{spec.fetch('separator').inspect}, empty reads #{spec.fetch('when_empty').inspect}"
      end

      # The local variable name `formatted_local` binds an argument's formatted value to.
      #
      # @param argument [String] the `RefusalSiteArgument` row's `"argument"` name
      # @return [String] the Rust local variable name `formatted_local` binds the
      #   formatted value to
      def local_name(argument) = "#{argument}_text"

      # An argument name, escaped for use as a Rust field/parameter identifier.
      #
      # @param argument [String] the `RefusalSiteArgument` row's `"argument"` name
      # @return [String] `argument`, prefixed with `r#` if it collides with a Rust
      #   keyword in `RUST_KEYWORDS`
      def rust_field(argument) = RUST_KEYWORDS.include?(argument) ? "r##{argument}" : argument

      # Renders the table's `#[cfg(test)]` module: every kind's `from_name` round-trip
      # test, plus `:order`'s and `:templates`' own tests.
      #
      # @param enum [String] the Rust enum name
      # @param kind [Symbol] the table's `:kind` (`:order`, `:templates`, or `:set`)
      # @param variants [Array<String>] each row's generated variant name, only
      #   read when `kind == :templates`
      # @param rows [Array<Hash{String => String}>] the table's rows, only read
      #   when `kind == :templates`
      # @param by_site [Hash{Array<String> => Array<Hash{String => String}>}, nil]
      #   each `[refusal, site]` pair's declared argument rows, only read when
      #   `kind == :templates`
      # @return [Array<String>] the `#[cfg(test)]` module's full source lines
      def tests(enum, kind, variants = [], rows = [], by_site = nil)
        list = kind == :order ? "ORDER" : "ALL"
        name = accessor_name(kind == :templates ? "site" : name_field(kind))
        lines = ["#[cfg(test)]",
                 "mod tests {",
                 "    use super::*;",
                 ""]
        unless kind == :templates
          lines += ["    #[test]",
                    "    fn every_row_is_found_by_its_own_name() {",
                    "        for row in #{enum}::#{list}.iter() {",
                    "            assert_eq!(#{enum}::from_name(row.#{name}()), Some(*row));",
                    "        }",
                    "    }",
                    ""]
        end
        lines += order_test(enum) if kind == :order
        if kind == :templates
          lines += placeholder_test(enum)
          lines += [""] + render_args_test(variants, rows, by_site)
        end
        lines.pop while lines.last == ""
        lines + ["}"]
      end

      # The `:order` kind's own test, checked into every order table's test module.
      #
      # @param enum [String] the Rust enum name
      # @return [Array<String>] the test asserting `ORDER`'s index matches each
      #   variant's `position`
      def order_test(enum)
        ["    #[test]",
         "    fn position_is_the_index_in_order() {",
         "        for (index, step) in #{enum}::ORDER.iter().enumerate() {",
         "            assert_eq!(step.position(), index);",
         "        }",
         "    }",
         ""]
      end

      # Placeholders are read off each template's own text, never a second
      # hand-kept list.
      #
      # @param enum [String] the Rust enum name
      # @return [Array<String>] the test asserting every site's `render` leaves
      #   no `{...}` placeholder unfilled
      def placeholder_test(enum)
        ["    #[test]",
         "    fn every_site_renders_with_no_leftover_placeholder() {",
         "        for site in #{enum}::ALL {",
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
         "    }"]
      end

      # The Ruby oracle, pinned. Every site renders through its typed
      # `render_args` for each edge case a list argument has — empty, one
      # item, several out of order — and must equal what
      # Runtime::RefusalWording.render_with answers for the same values,
      # computed here at generation time. Scalars carry a `"` so quoting
      # is compared too.
      #
      # @param variants [Array<String>] each row's generated variant name, matching `rows`
      # @param rows [Array<Hash{String => String}>] the `RefusalTemplate` rows, in
      #   the same order as `variants`
      # @param by_site [Hash{Array<String> => Array<Hash{String => String}>}] each
      #   `[refusal, site]` pair's declared argument rows, as built by `site_arguments`
      # @return [Array<String>] the test asserting every variant's `render_args`
      #   output for each `argument_cases` case matches
      #   `Runtime::RefusalWording.render_with`, computed here in Ruby
      def render_args_test(variants, rows, by_site)
        asserts = variants.zip(rows).flat_map do |variant, row|
          specs = by_site.fetch([row.fetch("refusal"), row.fetch("site")])
          argument_cases(specs).map do |arguments|
            expected = Runtime::RefusalWording.render_with(row.fetch("template"), specs, arguments)
            fields = specs.map do |spec|
              value = arguments.fetch(spec.fetch("argument").to_sym)
              rust_value = value.is_a?(Array) ? "&[#{value.map { |item| rust_string(item) }.join(', ')}]" : rust_string(value)
              "#{rust_field(spec.fetch('argument'))}: #{rust_value}"
            end
            ["        assert_eq!(",
             "            #{variant}Args { #{fields.join(', ')} }.render_args(),",
             "            #{rust_string(expected)}",
             "        );"]
          end
        end
        ["    #[test]",
         "    fn render_args_matches_ruby_render_site() {",
         asserts,
         "    }"].flatten
      end

      LIST_CASES = [[], ["only \"one\""], %w[zeta alpha mid]].freeze

      # Builds the argument-value cases `render_args_test` checks a site's
      # `render_args` against.
      #
      # @param specs [Array<Hash{String => String}>] one site's declared
      #   `RefusalSiteArgument` rows
      # @return [Array<Hash{Symbol => Object}>] one argument Hash per test case —
      #   `LIST_CASES` (empty, one item, several unsorted) if any spec is
      #   list-shaped, else a single scalar case, each scalar value carrying a `"`
      def argument_cases(specs)
        cases = specs.any? { |spec| spec.fetch("shape") == "list" } ? LIST_CASES : [nil]
        cases.map do |items|
          specs.to_h do |spec|
            name = spec.fetch("argument")
            [name.to_sym, spec.fetch("shape") == "list" ? items : "#{name} \"x\""]
          end
        end
      end

      # The row field a table's `from_name`/round-trip test treats as its "name".
      #
      # @param kind [Symbol] the table's `:kind` (`:order`, `:templates`, or `:set`)
      # @return [String] the row field used as this kind's "name" — `"step"` for
      #   `:order`, `"name"` otherwise
      def name_field(kind) = kind == :order ? "step" : "name"

      # `refusal` is a Rust-safe word but reads ambiguously beside the
      # kernel's own `Refusal` enum; the accessor says what it answers.
      #
      # @param field [String] a row field name, such as `"name"` or `"refusal"`
      # @return [String] the Rust accessor method name for `field` —
      #   `"refusal_class"` for `"refusal"`, `field` otherwise
      def accessor_name(field) = field == "refusal" ? "refusal_class" : field

      # Builds one row's Rust enum variant name from its declared `variant_from` fields.
      #
      # @param row [Hash{String => String}] the table row to name
      # @param fields [Array<String>] the row fields, PascalCased and concatenated
      #   in order to build the variant name
      # @return [String] the row's generated Rust enum variant name
      # @raise [ArgumentError] if the built name is not a valid Rust variant
      #   identifier (uppercase first letter, alphanumeric only)
      def variant_name(row, fields)
        name = fields.map { |field| pascal(row.fetch(field)) }.join
        raise ArgumentError, "#{name.inspect} is not a Rust variant name" unless name.match?(/\A[A-Z][A-Za-z0-9]*\z/)

        name
      end

      # PascalCases one field value for use inside a generated variant name.
      #
      # @param text [String, Symbol, nil] the value to PascalCase; each
      #   `_`-separated part's first letter is upcased
      # @return [String] `text` converted to PascalCase, or `""` if `text` is `nil`
      def pascal(text) = text.to_s.split("_").map { |part| part[0].to_s.upcase + part[1..].to_s }.join

      # A Rust string literal: only `\`, `"` and newlines need escaping in
      # the text any vocabulary row holds.
      #
      # @param text [String] the value to render as a Rust string literal
      # @return [String] `text`, backslash/quote/newline-escaped and wrapped in `"..."`
      def rust_string(text)
        escaped = text.to_s.gsub("\\") { "\\\\" }.gsub('"') { "\\\"" }.gsub("\n") { "\\n" }
        "\"#{escaped}\""
      end
    end
  end
end
