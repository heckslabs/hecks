require_relative "../projector"

module Hecks
  module Projections
    # Projects lib/hecks/vocabulary.rb from the chapter's `Vocabulary` aggregate.
    #
    #   Projector.call(:vocabulary, bluebook: <the Bluebook chapter>)
    #
    # Reads the chapter's judged IR, so the output is what the language holds.
    module Vocabulary
      extend Projector::Target

      projects_as :vocabulary, declares: "Vocabulary"

      HEADER = <<~RUBY.freeze
        # Generated — projected from the language's own Vocabulary aggregate
        # (lib/hecks/language/bluebook/vocabulary.bluebook).
        #
        # Do not edit. spec/vocabulary_table_spec.rb re-projects this in memory
        # and refuses a diff, so an edit here fails the ordinary suite.
        #
        # Plain data on purpose — no requires, no dependency on the model —
        # because several of these sets are read while a bluebook is still
        # being parsed. A table that needed the framework to load could not
        # be the table the framework loads with.
      RUBY

      module_function

      # The projector protocol; `options` is unused.
      #
      # @param bluebook [Bluebook::Behaviour::Chapter] the chapter declaring the
      #   Vocabulary aggregate to project
      # @param options [Hash] unused; accepted to satisfy the registry's call shape
      # @return [String] the rendered `lib/hecks/vocabulary.rb` source
      def call(bluebook:, options: {}) = render(bluebook)

      # Each closed set's full member rows, not just the first field.
      #
      # Some sets carry more than a term (`Comparison`, `RefusalTemplate`); taking
      # the first field of those yields duplicated names.
      #
      # @param bluebook [Bluebook::Behaviour::Chapter] the chapter declaring the
      #   Vocabulary aggregate to read
      # @return [Hash{String => Array<Hash{String => String}>}] each closed set's name,
      #   mapped to its member rows with every field stringified
      def tables(bluebook)
        bluebook.aggregate("Vocabulary").value_objects.to_h do |vo|
          [vo.hecks_name, vo.members.map { |row| row.to_h.transform_keys(&:to_s).transform_values(&:to_s) }]
        end
      end

      # Renders `lib/hecks/vocabulary.rb`'s full source: the frozen `TABLES`
      # and `TERMS` constants and the `fetch`/`rows`/`symbols`/`names` reader
      # methods, built from `bluebook`'s declared closed sets.
      #
      # @param bluebook [Bluebook::Behaviour::Chapter] the chapter declaring the
      #   Vocabulary aggregate to render
      # @return [String] the generated Ruby source, ready to write to disk
      def render(bluebook)
        rows = tables(bluebook).sort_by(&:first).map do |name, members|
          "      #{name.inspect} => [\n#{members.map { |row| "        #{row.inspect}.freeze" }.join(",\n")}\n      ].freeze"
        end

        <<~RUBY
          #{HEADER}
          module Hecks
            module Vocabulary
              TABLES = {
          #{rows.join(",\n")}
              }.freeze

              # The terms — the first field of each row, which for a
              # one-field vocabulary is the whole of it. Derived once and
              # frozen rather than mapped per call: these are constant
              # tables, and a constant that allocates a new array every
              # time it is read is not one.
              TERMS = TABLES.transform_values { |rows| rows.map { |row| row.values.first }.freeze }.freeze

              module_function

              # Refuses an unknown name rather than answering nil: a set
              # the language does not declare is a typo, not an empty set.
              def fetch(name) = TERMS.fetch(name)

              # The rows whole, for the vocabularies that carry more than
              # a term — Comparison's own algebra, RefusalTemplate's text.
              def rows(name) = TABLES.fetch(name)

              def symbols(name) = fetch(name).map(&:to_sym)

              def names = TABLES.keys
            end
          end
        RUBY
      end
    end
  end
end
