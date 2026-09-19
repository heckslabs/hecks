require_relative "../projector"
require_relative "../runtime/refusal_wording"
require_relative "vocabulary"

module Hecks
  module Projections
    # **Projected into the Rust kernel** — one
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
    # ## Only the tables the kernel needs
    #
    # Each entry in `TABLES` names its enum and its generated extras; a
    # table not listed is not projected. The enum names that differ from
    # the table name keep existing Rust call sites (`RefusalSite`) and
    # the dispatch-step names D1 consumes (`AggregateStep`, `EntityStep`).
    #
    # ## Typed refusal arguments
    #
    # The templates table also reads RefusalSiteArgument: every site gets
    # a `<Variant>Args` struct whose fields are exactly the site's
    # declared arguments (a `&str` per scalar, a `&[&str]` per list) and
    # a `render_args` that formats each one by its row. `render` itself
    # stays private to the generated module, so no call site can pass an
    # argument list by hand — leaving one out does not compile. The
    # generated test pins every site's `render_args` output (empty,
    # single and multiple unsorted lists) against
    # `Runtime::RefusalWording.render_with`, computed here in Ruby.
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

      # Projects `bluebook`'s closed sets as the Rust kernel's vocab module.
      #
      # @param bluebook [Bluebook::Behaviour::Chapter] the chapter declaring the
      #   Vocabulary aggregate to project
      # @param options [Hash] unused; accepted to satisfy the registry's call shape
      # @return [Hash{String => String}] each generated file's path (relative to
      #   `rust/src/kernel/`), mapped to its Rust source
      def call(bluebook:, options: {}) = render(bluebook)

      # Renders every `TABLES`-listed table plus the `vocab/mod.rs` that
      # `pub use`s all their enums.
      #
      # @param bluebook [Bluebook::Behaviour::Chapter] the chapter declaring the
      #   Vocabulary aggregate to project
      # @return [Hash{String => String}] each generated file's path, mapped to its
      #   Rust source
      # @raise [ArgumentError] if `bluebook` declares no table a `TABLES` entry names
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

      # Renders the "GENERATED by ..." doc-comment header shared by every
      # generated table file.
      #
      # @param table [String] the Vocabulary table's name, such as `"QueryComparator"`
      # @return [String] the "GENERATED by ..." doc-comment header, common to every
      #   generated table file
      def header(table)
        <<~RUST
          // GENERATED by #{GENERATOR} (Hecks::Projections::RustVocabulary,
          // lib/hecks/projections/rust_vocabulary.rb) from Vocabulary::#{table}
          // (#{SOURCE}).
          // Do not hand-edit — re-run #{GENERATOR} instead.
        RUST
      end

      # Renders `vocab/mod.rs`, declaring and re-exporting every table's module.
      #
      # @return [String] the `vocab/mod.rs` source, declaring and re-exporting
      #   every `TABLES`-listed table's own module
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

      # Renders one Vocabulary table as a Rust enum module: the enum itself,
      # its accessors and constants, and (for `:templates`) its typed
      # argument structs and generated tests.
      #
      # @param table [String] the Vocabulary table's name
      # @param spec [Hash{Symbol => Object}] this table's own `TABLES` entry
      # @param rows [Array<Hash{String => String}>] the table's own rows, every
      #   field stringified
      # @param argument_rows [Array<Hash{String => String}>, nil] the
      #   RefusalSiteArgument rows, when `spec[:kind]` is `:templates`; nil otherwise
      # @return [String] the table's generated Rust module source
      # @raise [ArgumentError] if two rows would mint the same enum variant name
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

      # Renders the enum's `ORDER` or `ALL` constant declaration.
      #
      # @param enum [String] the enum's Rust name
      # @param variants [Array<String>] every row's own variant name, in row order
      # @param kind [Symbol] the table's `TABLES` kind (`:order`, `:set`, or `:templates`)
      # @return [Array] the `ORDER` or `ALL` constant declaration, as nested Rust
      #   source line fragments (strings and arrays thereof)
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

      # Renders one field's `pub fn` accessor method.
      #
      # @param enum [String] the enum's Rust name
      # @param field [String] the row field this accessor reads, such as `"name"`
      # @param variants [Array<String>] every row's own variant name, in row order
      # @param rows [Array<Hash{String => String}>] the table's own rows, in the
      #   same order as `variants`
      # @return [Array] the field's `pub fn` accessor, as nested Rust source line
      #   fragments
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
      # @param enum [String] the enum's Rust name
      # @param kind [Symbol] the table's `TABLES` kind
      # @return [Array] the `from_name` lookup function, as nested Rust source line
      #   fragments
      def from_name(enum, kind)
        list  = kind == :order ? "ORDER" : "ALL"
        field = kind == :templates ? "site" : name_field(kind)
        ["    /// The row whose `#{field}` is `name`, if any.",
         "    pub fn from_name(name: &str) -> Option<#{enum}> {",
         "        #{enum}::#{list}.iter().copied().find(|row| row.#{accessor_name(field)}() == name)",
         "    }",
         ""]
      end

      # Renders whatever extra methods `kind` adds beyond the shared ones.
      #
      # @param enum [String] the enum's Rust name
      # @param variants [Array<String>] every row's own variant name, in row order
      # @param kind [Symbol] the table's `TABLES` kind
      # @return [Array] `kind`'s extra methods (`position` for `:order`, `render` for
      #   `:templates`), as nested Rust source line fragments; empty for `:set`
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
      # @param rows [Array<Hash{String => String}>] the RefusalTemplate rows
      # @param argument_rows [Array<Hash{String => String}>] the RefusalSiteArgument
      #   rows
      # @return [Hash{Array(String, String) => Array<Hash{String => String}>}] every
      #   `[refusal, site]` pair, mapped to its own argument rows
      # @raise [ArgumentError] if an argument row names a `[refusal, site]` no
      #   RefusalTemplate row declares, a site's argument names do not exactly
      #   match its template's placeholders in order, or any row fails `check_rule!`
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

      # Refuses an argument row with an unrecognized shape, quoting rule, or a
      # `sorted` value that is not `"true"`/`"false"`.
      #
      # @param key [Array(String, String)] the `[refusal, site]` pair `spec` belongs
      #   to, used in the message when refusing
      # @param spec [Hash{String => String}] the RefusalSiteArgument row to check
      # @return [void]
      # @raise [ArgumentError] if `spec`'s `"shape"`, `"quoting"`, or `"sorted"` is
      #   not a recognized value
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

      # Renders the shared formatting helpers and every variant's own args struct.
      #
      # @param enum [String] the enum's Rust name
      # @param variants [Array<String>] every row's own variant name, in row order
      # @param rows [Array<Hash{String => String}>] the RefusalTemplate rows, in the
      #   same order as `variants`
      # @param by_site [Hash{Array(String, String) => Array<Hash{String => String}>}]
      #   every `[refusal, site]` pair, mapped to its own argument rows (as
      #   `site_arguments` builds)
      # @return [Array] the shared `quoted`/`list` helper functions, followed by
      #   every variant's own `<Variant>Args` struct, as nested Rust source line
      #   fragments
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

      # Renders one variant's own typed argument struct and its `render_args` impl.
      #
      # @param enum [String] the enum's Rust name
      # @param variant [String] this row's own variant name
      # @param row [Hash{String => String}] the RefusalTemplate row this struct is for
      # @param specs [Array<Hash{String => String}>] `row`'s own RefusalSiteArgument rows
      # @return [Array] the `<Variant>Args` struct and its `render_args` impl, as
      #   nested Rust source line fragments
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

      # Renders a `let` binding for one argument, if it needs pre-formatting.
      #
      # @param spec [Hash{String => String}] the RefusalSiteArgument row to format
      # @return [String, nil] a `let` binding formatting this argument (a joined
      #   list, or a quoted scalar), or nil if it needs no local (an unquoted scalar)
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

      # Describes one argument's formatting rule in plain English.
      #
      # @param spec [Hash{String => String}] the RefusalSiteArgument row to describe
      # @return [String] a plain-English reading of `spec`'s formatting rule, used in
      #   the generated field's own doc comment
      def rule_reading(spec)
        quoting = spec.fetch("quoting") == "inspect" ? ", quoted" : ""
        return "scalar#{quoting}" unless spec.fetch("shape") == "list"

        sorted = spec.fetch("sorted") == "true" ? ", sorted" : ""
        "list#{sorted}#{quoting}, joined #{spec.fetch('separator').inspect}, empty reads #{spec.fetch('when_empty').inspect}"
      end

      # Names the local variable a pre-formatted argument is bound to.
      #
      # @param argument [String] the argument's declared name
      # @return [String] the local variable name `formatted_local` binds it to
      def local_name(argument) = "#{argument}_text"

      # Escapes an argument name that collides with a Rust keyword.
      #
      # @param argument [String] the argument's declared name
      # @return [String] `argument`, prefixed `r#` if it is a Rust keyword
      def rust_field(argument) = RUST_KEYWORDS.include?(argument) ? "r##{argument}" : argument

      # Renders the enum's `#[cfg(test)] mod tests { ... }` block.
      #
      # @param enum [String] the enum's Rust name
      # @param kind [Symbol] the table's `TABLES` kind
      # @param variants [Array<String>] every row's own variant name, in row order
      # @param rows [Array<Hash{String => String}>] the table's own rows, in the
      #   same order as `variants`
      # @param by_site [Hash{Array(String, String) => Array<Hash{String => String}>}, nil]
      #   every `[refusal, site]` pair's own argument rows, when `kind` is
      #   `:templates`; unused otherwise
      # @return [Array] the `#[cfg(test)] mod tests { ... }` block, as nested Rust
      #   source line fragments
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

      # Generates the test pinning `position` against `ORDER`'s own index.
      #
      # @param enum [String] the enum's Rust name
      # @return [Array<String>] the `position_is_the_index_in_order` test, as Rust
      #   source lines
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
      # @param enum [String] the enum's Rust name
      # @return [Array<String>] the `every_site_renders_with_no_leftover_placeholder`
      #   test, as Rust source lines
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

      # Generates the test pinning every site's `render_args` against Ruby.
      #
      # **The Ruby oracle, pinned.** Every site renders through its typed
      # `render_args` for each edge case a list argument has — empty, one
      # item, several out of order — and must equal what
      # Runtime::RefusalWording.render_with answers for the same values,
      # computed here at generation time. Scalars carry a `"` so quoting
      # is compared too.
      #
      # @param variants [Array<String>] every row's own variant name, in row order
      # @param rows [Array<Hash{String => String}>] the RefusalTemplate rows, in the
      #   same order as `variants`
      # @param by_site [Hash{Array(String, String) => Array<Hash{String => String}>}]
      #   every `[refusal, site]` pair's own argument rows
      # @return [Array] the `render_args_matches_ruby_render_site` test, as nested
      #   Rust source line fragments
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

      # Builds the edge-case argument sets `render_args_test` checks each site
      # against.
      #
      # @param specs [Array<Hash{String => String}>] one site's own argument rows
      # @return [Array<Hash{Symbol => String, Array<String>, nil}>] one Hash per test
      #   case, mapping each argument's name to its value for that case (`LIST_CASES`
      #   when any argument is a list, a single scalar case otherwise)
      def argument_cases(specs)
        cases = specs.any? { |spec| spec.fetch("shape") == "list" } ? LIST_CASES : [nil]
        cases.map do |items|
          specs.to_h do |spec|
            name = spec.fetch("argument")
            [name.to_sym, spec.fetch("shape") == "list" ? items : "#{name} \"x\""]
          end
        end
      end

      # Names the row field `from_name` looks a name up by.
      #
      # @param kind [Symbol] the table's `TABLES` kind
      # @return [String] the row field `from_name` looks a name up by: `"step"` for
      #   `:order`, `"name"` otherwise
      def name_field(kind) = kind == :order ? "step" : "name"

      # `refusal` is a Rust-safe word but reads ambiguously beside the
      # kernel's own `Refusal` enum; the accessor says what it answers.
      #
      # @param field [String] the row field to name an accessor for
      # @return [String] `field`'s Rust accessor method name
      def accessor_name(field) = field == "refusal" ? "refusal_class" : field

      # Mints a row's own Rust enum variant name from its variant-naming fields.
      #
      # @param row [Hash{String => String}] the row to name a variant for
      # @param fields [Array<String>] the row fields (in `TABLES[table][:variant_from]`
      #   order) whose values, PascalCased and concatenated, name the variant
      # @return [String] the row's own Rust enum variant name
      # @raise [ArgumentError] if the built name is not a valid Rust variant identifier
      def variant_name(row, fields)
        name = fields.map { |field| pascal(row.fetch(field)) }.join
        raise ArgumentError, "#{name.inspect} is not a Rust variant name" unless name.match?(/\A[A-Z][A-Za-z0-9]*\z/)

        name
      end

      # PascalCases a snake_case token.
      #
      # @param text [String, Symbol] a snake_case (or single-word) token
      # @return [String] `text` PascalCased
      def pascal(text) = text.to_s.split("_").map { |part| part[0].to_s.upcase + part[1..].to_s }.join

      # A Rust string literal: only `\`, `"` and newlines need escaping in
      # the text any vocabulary row holds.
      #
      # @param text [String, Symbol, nil] the value to render
      # @return [String] `text`, as a quoted, escaped Rust string literal
      def rust_string(text)
        escaped = text.to_s.gsub("\\") { "\\\\" }.gsub('"') { "\\\"" }.gsub("\n") { "\\n" }
        "\"#{escaped}\""
      end
    end
  end
end
