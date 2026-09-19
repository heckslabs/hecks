require_relative "../projector"

module Hecks
  module Projections
    # The Rust parser's keyword table, projected from the chapter's own
    # Syntax aggregate — "the parser's grammar knowledge is derived from
    # hecks's self-description, not hand-typed a second time", which
    # is the anti-drift idea the whole Rust-parser plan rests on.
    #
    # A registered target now, rather than a module living inside its own
    # bin/ script. It was already a projection in everything but call
    # shape; this only stops it being a fifth way of spelling one.
    module ParserTable
      extend Projector::Target
      projects_as :parser_table, declares: "Syntax"

      module_function

      # Projects the Rust parser's keyword table for `bluebook`.
      #
      # @param bluebook [Bluebook::Behaviour::Chapter] the chapter declaring the
      #   Syntax aggregate to render
      # @param options [Hash] unused; accepted to satisfy the registry's call shape
      # @return [String] the generated Rust source
      def call(bluebook:, options: {}) = render(bluebook)

      module_function

      # The chapter is handed over, not reached for, so the projection can
      # run against any chapter rather than only the language's own — which
      # is what the projector protocol asks for, and costs nothing.
      #
      # @param bluebook [Bluebook::Behaviour::Chapter] the chapter to read from
      # @return [Bluebook::Aggregate, nil] `bluebook`'s Syntax aggregate, or nil if
      #   it declares none
      def syntax(bluebook) = bluebook.aggregate("Syntax")

      # Every cell as text — exactly spec/syntax_conformance_spec.rb's own
      # `rows` helper, reused rather than re-derived: a member's fields decode
      # back through typed literal decoding on the way out of reconstruction,
      # and this reads it back as what was written.
      #
      # @param bluebook [Bluebook::Behaviour::Chapter] the chapter to read from
      # @param name [String] the closed set's name, such as `"Context"`
      # @return [Array<Hash{Symbol => String}>] the closed set's member rows, every
      #   field stringified
      def rows(bluebook, name)
        syntax(bluebook).value_objects.find { |vo| vo.hecks_name == name }
              .members.map { |row| row.to_h.transform_values(&:to_s) }
      end

      # Names one closed set's members.
      #
      # @param bluebook [Bluebook::Behaviour::Chapter] the chapter to read from
      # @param name [String] the closed set's name, such as `"Context"`
      # @return [Array<String>] the closed set's member names
      def closed_set_members(bluebook, name) = rows(bluebook, name).map { |row| row[:name] }

      KEYWORD_FIELDS  = %i[word context body inner opens fills status was resolves_via disambiguator].freeze
      ARGUMENT_FIELDS = %i[keyword context at named kind required fills selects
                           pair_key_fills pair_value_fills pairs_shape status variadic minimum].freeze

      # A Rust string literal for one field's value — every field here is
      # plain ASCII (a word, a context name, a digit, "true"/"false"), so this
      # only has to be safe against the two characters Rust string literals
      # themselves reserve.
      #
      # @param value [String, nil] the value to render; nil renders as `""`
      # @return [String] `value`, as a quoted, escaped Rust string literal
      def rust_string(value) = "\"#{value.to_s.gsub('\\', '\\\\\\\\').gsub('"', '\\"')}\""

      # Renders one keyword row as a Rust struct literal.
      #
      # @param row [Hash{Symbol => String}] a keyword row, keyed by `KEYWORD_FIELDS`
      # @return [String] the row as a Rust `KeywordRow { ... },` struct literal line
      def keyword_row(row)
        fields = KEYWORD_FIELDS.map { |field| rust_string(row[field]) }
        "    KeywordRow { #{KEYWORD_FIELDS.zip(fields).map { |name, value| "#{name}: #{value}" }.join(', ')} },"
      end

      # Renders one argument row as a Rust struct literal.
      #
      # @param row [Hash{Symbol => String}] an argument row, keyed by `ARGUMENT_FIELDS`
      # @return [String] the row as a Rust `ArgumentRow { ... },` struct literal line
      def argument_row(row)
        fields = ARGUMENT_FIELDS.map { |field| rust_string(row[field]) }
        "    ArgumentRow { #{ARGUMENT_FIELDS.zip(fields).map { |name, value| "#{name}: #{value}" }.join(', ')} },"
      end

      # Renders a Rust static string-slice array declaration.
      #
      # @param name [String] the Rust static's name
      # @param values [Array<String>] the strings to render into the array
      # @return [String] a `pub static NAME: &[&str] = &[...];` Rust declaration
      def const_str_array(name, values)
        lines = values.map { |value| "    #{rust_string(value)}," }
        "pub static #{name}: &[&str] = &[\n#{lines.join("\n")}\n];\n"
      end

      # Renders the full Rust source for `bluebook`'s parser keyword table.
      #
      # S14, ADR 0026 — Keyword/Argument are genuine entities of Syntax
      # now, dispatched (not merely declared) so their own `status`
      # really is a lifecycle. `SyntaxBoot.call` reads the still-static
      # seed rows (`KeywordSeed`/`ArgumentSeed`), dispatches each one
      # through the real admission/lifecycle door, and hands back the
      # same shape `rows` reads directly off the closed set — symbol
      # keys, string values, `status` included — so nothing else in
      # this file needs to change.
      #
      # @param bluebook [Bluebook::Behaviour::Chapter] the chapter to read the
      #   Context/Body/ArgumentKind/PairsShape/Status closed sets from
      # @return [String] the generated Rust source, ready to write to disk
      def render(bluebook)
        table     = Hecks::Bluebook::MetaValidator::SyntaxBoot.call
        keywords  = table[:keywords]
        arguments = table[:arguments]

        <<~RUST
          // GENERATED by bin/project_parser_table from
          // aggregate-local syntax tables under lib/hecks/language/ — DO NOT EDIT BY HAND.
          //
          // Re-run `bin/project_parser_table` after any syntax-table change.
          // spec/parser_table_spec.rb regenerates this into memory and fails the
          // normal `bundle exec rspec` suite the moment this file drifts from what
          // the language currently declares — see that spec and
          // bin/project_parser_table's own header for why this file is never
          // hand-edited.

          #[derive(Debug, Clone, Copy)]
          pub struct KeywordRow {
              pub word: &'static str,
              pub context: &'static str,
              pub body: &'static str,
              pub inner: &'static str,
              pub opens: &'static str,
              pub fills: &'static str,
              pub status: &'static str,
              pub was: &'static str,
              /// Which shared Hecks::Bluebook::DSL::RuleReference
              /// primitive this word's own bare form resolves through,
              /// once it has one ("hash_chain" / "owner_keyed" /
              /// "sibling_scan") — "" for every word that only ever
              /// declares.
              pub resolves_via: &'static str,
              /// Which disambiguator keyword argument a bare reference
              /// may supply — "declared_by" today, "" otherwise.
              pub disambiguator: &'static str,
          }

          #[derive(Debug, Clone, Copy)]
          pub struct ArgumentRow {
              pub keyword: &'static str,
              pub context: &'static str,
              pub at: &'static str,
              pub named: &'static str,
              pub kind: &'static str,
              pub required: &'static str,
              pub fills: &'static str,
              pub selects: &'static str,
              pub pair_key_fills: &'static str,
              pub pair_value_fills: &'static str,
              pub pairs_shape: &'static str,
              pub status: &'static str,
              pub variadic: &'static str,
              pub minimum: &'static str,
          }

          impl KeywordRow {
              /// An absent status reads as admitted — the grown-column convention
              /// syntax_conformance_spec.rb's own `status_of`/`live?` already use.
              pub fn live(&self) -> bool {
                  matches!(self.status, "" | "admitted" | "deprecated")
              }
          }

          impl ArgumentRow {
              pub fn live(&self) -> bool {
                  matches!(self.status, "" | "admitted" | "deprecated")
              }
          }

          pub static KEYWORDS: &[KeywordRow] = &[
          #{keywords.map { |row| keyword_row(row) }.join("\n")}
          ];

          pub static ARGUMENTS: &[ArgumentRow] = &[
          #{arguments.map { |row| argument_row(row) }.join("\n")}
          ];

          #{const_str_array('CONTEXTS', closed_set_members(bluebook, 'Context'))}
          #{const_str_array('BODIES', closed_set_members(bluebook, 'Body'))}
          #{const_str_array('ARGUMENT_KINDS', closed_set_members(bluebook, 'ArgumentKind'))}
          #{const_str_array('PAIRS_SHAPES', closed_set_members(bluebook, 'PairsShape'))}
          #{const_str_array('STATUSES', closed_set_members(bluebook, 'Status'))}
        RUST
      end
    end
  end
end
