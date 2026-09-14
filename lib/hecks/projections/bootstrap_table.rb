require_relative "../projector"

module Hecks
  module Projections
    # THE BOOTSTRAP-WINDOW FALLBACKS, PROJECTED — lib/hecks/bluebook/dsl/
    # bootstrap_table.rb rendered from the chapter's own Keyword rows.
    #
    #   Projector.call(:bootstrap_table, bluebook: <the Bluebook chapter>)
    #
    # While `MetaValidator.bootstrapping?` the grammar table does not exist
    # yet, so `WordGate#method_missing` and `RuleReference#lookup` cannot
    # read `calls:`/`resolves_via:`/`disambiguator:` off it. They used to
    # read two hand-kept Hashes instead, each "kept in sync by hand" with
    # those columns. Kept in sync by hand meant a SUBSET: 48 of the 87 live
    # `calls:` rows, chosen word by word by grepping which ones the core
    # chapters happened to use during bootstrap. A partition, not a filter:
    # every live row now lands in the table, and the ones no bootstrap
    # chapter calls cost nothing — a builder with its own `def` never
    # reaches `method_missing` at all.
    #
    # The table cannot be BUILT at boot for the same reason it exists: it
    # is read before the grammar it comes from has been assembled. So it is
    # committed, like lib/hecks/vocabulary.rb, and spec/bootstrap_table_
    # spec.rb re-projects it in memory and refuses a diff.
    module BootstrapTable
      extend Projector::Target

      projects_as :bootstrap_table, declares: "Syntax"

      class Conflict < StandardError; end

      HEADER = <<~RUBY.freeze
        # GENERATED — projected from the language's own Keyword rows (the
        # `calls:`, `resolves_via:` and `disambiguator:` columns of every
        # KeywordSeed under lib/hecks/language/).
        #
        # DO NOT EDIT. spec/bootstrap_table_spec.rb re-projects this in memory
        # and refuses a diff — run bin/project_bootstrap_table instead.
        #
        # Plain data, no requires: this is read WHILE the grammar table it was
        # projected from is still being built (`MetaValidator.bootstrapping?`).
      RUBY

      module_function

      def call(bluebook:, options: {}) = render(bluebook)

      # Retired rows are out of the language; admitted and deprecated rows
      # still dispatch — the same `status != "retired"` reading
      # `GenericDispatch.shape_for` gives the live table.
      def live_keywords
        Bluebook::MetaValidator::SyntaxBoot.call[:keywords].reject { |row| row[:status] == "retired" }
      end

      # `[context, word] => :method` — WordGate's own key order.
      #
      # An overloaded word has one row per argument shape, and they all
      # name the same method. Two that DON'T would make the table keep
      # whichever came last, so that is refused instead.
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
      def resolves(rows = live_keywords)
        rows.reject { |row| row[:resolves_via].to_s.empty? }.to_h do |row|
          rule = { resolves_via: row[:resolves_via], disambiguator: row[:disambiguator] }
          [[row[:word], row[:context]], rule.reject { |_, value| value.to_s.empty? }]
        end
      end

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
