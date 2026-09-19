require_relative "../projector"

module Hecks
  module Projections
    # **The bootstrap-window fallbacks, projected** — lib/hecks/bluebook/dsl/
    # bootstrap_table.rb rendered from the chapter's own Keyword rows.
    #
    #   Projector.call(:bootstrap_table, bluebook: <the Bluebook chapter>)
    #
    # While `MetaValidator.bootstrapping?` the grammar table does not exist
    # yet, so `WordGate#method_missing` and `RuleReference#lookup` cannot
    # read `calls:`/`resolves_via:`/`disambiguator:` off it — this table is
    # what they read instead.
    #
    # A partition, not a filter: every live row lands in the table, not only
    # the ones a bootstrap chapter happens to call. Picking a subset by
    # grepping which words the core chapters use during bootstrap would risk
    # quietly dropping any word a chapter starts using later. Including
    # every row instead costs nothing: a builder with its own `def` never
    # reaches `method_missing` at all, so a row no bootstrap chapter calls
    # is simply never read.
    #
    # The table cannot be built at boot for the same reason it exists: it
    # is read before the grammar it comes from has been assembled. So it is
    # committed, like lib/hecks/vocabulary.rb, and spec/bootstrap_table_
    # spec.rb re-projects it in memory and refuses a diff.
    module BootstrapTable
      extend Projector::Target

      projects_as :bootstrap_table, declares: "Syntax"

      class Conflict < StandardError; end

      HEADER = <<~RUBY.freeze
        # Generated — projected from the language's own Keyword rows (the
        # `calls:`, `resolves_via:` and `disambiguator:` columns of every
        # KeywordSeed under lib/hecks/language/).
        #
        # Do not edit. spec/bootstrap_table_spec.rb re-projects this in memory
        # and refuses a diff — run bin/project_bootstrap_table instead.
        #
        # Plain data, no requires: this is read while the grammar table it was
        # projected from is still being built (`MetaValidator.bootstrapping?`).
      RUBY

      module_function

      # Projects the bootstrap fallback table — the only real work this projector
      # does, `bluebook` unused because the table is the whole language's grammar,
      # not any one chapter's.
      #
      # @param bluebook [Bluebook::Chapter] ignored; present to satisfy the
      #   `Projector::Target` calling convention
      # @param options [Hash{Symbol => Object}] ignored; present to satisfy the
      #   `Projector::Target` calling convention
      # @return [String] the rendered `lib/hecks/bluebook/dsl/bootstrap_table.rb` source
      def call(bluebook:, options: {}) = render(bluebook)

      # Retired rows are out of the language; admitted and deprecated rows
      # still dispatch — the same `status != "retired"` reading
      # `GenericDispatch.shape_for` gives the live table.
      #
      # @return [Array<Hash{Symbol => String}>] every non-retired keyword row, each with
      #   at least `:context`, `:word`, `:status`, `:calls`, `:resolves_via` and
      #   `:disambiguator`, values stringified
      def live_keywords
        Bluebook::MetaValidator::SyntaxBoot.call[:keywords].reject { |row| row[:status] == "retired" }
      end

      # `[context, word] => :method` — WordGate's own key order.
      #
      # An overloaded word has one row per argument shape, and they all
      # name the same method. Two that don't would make the table keep
      # whichever came last, so that is refused instead.
      #
      # @param rows [Array<Hash{Symbol => String}>] the keyword rows to build from,
      #   defaulting to every live one
      # @return [Hash{Array(String, String) => Symbol}] each `calls:`-declaring row's
      #   `[context, word]` mapped to the method name it dispatches to
      # @raise [Projections::BootstrapTable::Conflict] if two rows sharing a
      #   `[context, word]` name different methods
      def calls(rows = live_keywords)
        rows.reject { |row| row[:calls].to_s.empty? }
            .group_by { |row| [row[:context], row[:word]] }
            .to_h do |key, same_word|
              targets = same_word.map { |row| row[:calls] }.uniq
              raise Conflict, "#{key.inspect} names more than one method: #{targets.join(', ')}" if targets.size > 1

              [key, targets.first.to_sym]
            end
      end

      # `[word, context] => { resolves_via:, disambiguator: }` —
      # RuleReference's own key order, blank columns omitted, the same
      # shape its live `lookup` answers.
      #
      # @param rows [Array<Hash{Symbol => String}>] the keyword rows to build from,
      #   defaulting to every live one
      # @return [Hash{Array(String, String) => Hash{Symbol => String}}] each
      #   `resolves_via:`-declaring row's `[word, context]` mapped to its rule Hash,
      #   with any blank `resolves_via`/`disambiguator` column omitted
      def resolves(rows = live_keywords)
        rows.reject { |row| row[:resolves_via].to_s.empty? }.to_h do |row|
          rule = { resolves_via: row[:resolves_via], disambiguator: row[:disambiguator] }
          [[row[:word], row[:context]], rule.reject { |_, value| value.to_s.empty? }]
        end
      end

      # Renders the bootstrap table as committable Ruby source — `CALLS` and
      # `RESOLVES` frozen Hash literals under the generated-file header.
      #
      # @param _bluebook [Bluebook::Chapter] ignored; the table draws from the whole
      #   language's grammar, not this argument
      # @return [String] the full `lib/hecks/bluebook/dsl/bootstrap_table.rb` source,
      #   ready to write to disk
      def render(_bluebook)
        rows = live_keywords
        calls_lines = calls(rows).map { |key, target| "          #{key.inspect} => #{target.inspect}" }
        resolves_lines = resolves(rows).map do |key, rule|
          fields = rule.map { |name, value| "#{name}: #{value.inspect}" }.join(", ")
          "          #{key.inspect} => { #{fields} }.freeze"
        end

        <<~RUBY
          #{HEADER}
          module Hecks
            module Bluebook
              module DSL
                module BootstrapTable
                  # [context, word] => the method a word's whole call forwards to.
                  CALLS = {
          #{calls_lines.join(",\n")}
                  }.freeze

                  # [word, context] => the RuleReference primitive a bare reference resolves through.
                  RESOLVES = {
          #{resolves_lines.join(",\n")}
                  }.freeze
                end
              end
            end
          end
        RUBY
      end
    end
  end
end
