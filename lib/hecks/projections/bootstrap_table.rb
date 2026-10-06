require_relative "../projector"

module Hecks
  module Projections
    # Projects lib/hecks/bluebook/dsl/bootstrap_table.rb from the chapter's Keyword rows.
    # Committed, not built at boot: it is read before the grammar table exists.
    #
    #   Projector.call(:bootstrap_table, bluebook: <the Bluebook chapter>)
    #
    # Every live row is included, not only those a bootstrap chapter calls.
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
        # and refuses a diff — run hecks project_bootstrap_table instead.
        #
        # Plain data, no requires: this is read while the grammar table it was
        # projected from is still being built (`MetaValidator.bootstrapping?`).
      RUBY

      # The generated file, with `@@CALLS@@` and `@@RESOLVES@@` standing for the table rows.
      TEMPLATE = <<~RUBY.freeze
        #{HEADER}
        module Hecks
          module Bluebook
            module DSL
              module BootstrapTable
                # [context, word] => the method a word's whole call forwards to.
                CALLS = {
        @@CALLS@@
                }.freeze

                # [word, context] => the RuleReference primitive a bare reference resolves through.
                RESOLVES = {
        @@RESOLVES@@
                }.freeze
              end
            end
          end
        end
      RUBY

      module_function

      # Projects the bootstrap fallback table; both arguments are ignored (the table is
      # the whole grammar) and exist for the `Projector::Target` calling convention.
      #
      # @return [String] the rendered `lib/hecks/bluebook/dsl/bootstrap_table.rb` source
      def call(bluebook:, options: {}) = render(bluebook)

      # Every keyword row that is not retired; admitted and deprecated rows still dispatch.
      #
      # @return [Array<Hash{Symbol => String}>] every non-retired keyword row, each with
      #   at least `:context`, `:word`, `:status`, `:calls`, `:resolves_via` and
      #   `:disambiguator`, values stringified
      def live_keywords
        Bluebook::MetaValidator::SyntaxBoot.call[:keywords].reject { |row| row[:status] == "retired" }
      end

      # `[context, word] => :method`, in WordGate's key order.
      # Overloaded rows must all name the same method; a mismatch raises rather than last-wins.
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
            .to_h { |key, same_word| [key, single_target(key, same_word)] }
      end

      # @param key [Array<String>] a `[context, word]`
      # @param same_word [Array<Hash{Symbol => String}>] the rows declaring that word
      # @return [Symbol] the one method they all name
      # @raise [Projections::BootstrapTable::Conflict] if they name different methods
      def single_target(key, same_word)
        targets = same_word.map { |row| row[:calls] }.uniq
        raise Conflict, "#{key.inspect} names more than one method: #{targets.join(", ")}" if targets.size > 1

        targets.first.to_sym
      end

      # `[word, context] => { resolves_via:, disambiguator: }`, in RuleReference's key order.
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

      # Renders the `CALLS` and `RESOLVES` frozen Hash literals as Ruby source.
      #
      # @return [String] the full `lib/hecks/bluebook/dsl/bootstrap_table.rb` source
      def render(_bluebook)
        rows = live_keywords
        calls_lines = calls(rows).map { |key, target| "          #{key.inspect} => #{target.inspect}" }
        resolves_lines = resolves(rows).map { |key, rule| resolves_line(key, rule) }

        TEMPLATE.sub("@@CALLS@@") { calls_lines.join(",\n") }.sub("@@RESOLVES@@") { resolves_lines.join(",\n") }
      end

      # @param key [Array<String>] a `[word, context]`
      # @param rule [Hash{Symbol => String}] its `resolves_via:` and `disambiguator:` columns
      # @return [String] its entry in the `RESOLVES` literal
      def resolves_line(key, rule)
        fields = rule.map { |name, value| "#{name}: #{value.inspect}" }.join(", ")
        "          #{key.inspect} => { #{fields} }.freeze"
      end
    end
  end
end
