module Hecksagain
  module Projections
    # THE CLOSED SETS, PROJECTED — lib/hecksagain/vocabulary.rb rendered
    # from whichever chapter declares a `Vocabulary` aggregate, which in
    # practice is the language projecting its own tables.
    #
    #   Projector.call(:vocabulary, bluebook: <the Bluebook chapter>)
    #
    # A PROJECTION RATHER THAN A BIN/ SCRIPT, and that correction is the
    # point of it. This was first written as its own program with its own
    # call shape, beside `bin/project_parser_table`, `bin/reference` and
    # `bin/expression_projection` — four tools doing "canonical IR in,
    # external artifact out" four different ways, which is the exact
    # thing the projector registry exists to stop.
    #
    # Reads the chapter's JUDGED IR, so what is written out is what the
    # language actually holds rather than what a builder happened to
    # produce.
    module Vocabulary
      extend Projector::Target
      projects_as :vocabulary

      HEADER = <<~RUBY.freeze
        # GENERATED — projected from the language's own Vocabulary aggregate
        # (lib/hecksagain/language/bluebook/vocabulary.bluebook).
        #
        # DO NOT EDIT. spec/vocabulary_table_spec.rb re-projects this in memory
        # and refuses a diff, so an edit here fails the ordinary suite.
        #
        # Plain data on purpose — no requires, no dependency on the model —
        # because several of these sets are read while a bluebook is still
        # being parsed. A table that needed the framework to load could not
        # be the table the framework loads with.
      RUBY

      module_function

      # The projector protocol. `options` is unused: a vocabulary table
      # has nothing to vary.
      def call(bluebook:, options: {}) = render(bluebook)

      # FULL ROWS, not just the first field of each.
      #
      # Most vocabularies ARE one-field lists and the field is the term.
      # Several are not: `Comparison` declares the algebra each operator
      # computes with, `RefusalTemplate` an error plus its key and text.
      # Taking the first field of those produced a list of thirty-nine
      # duplicated error names — well-formed and meaningless. So rows are
      # carried whole, and the terms are derived from them.
      def tables(bluebook)
        aggregate = bluebook.aggregates.find { |a| a.name == "Vocabulary" } or
          raise Projector::WrongConstruct, "#{bluebook.name} declares no Vocabulary aggregate"

        aggregate.value_objects.to_h do |vo|
          [vo.hecks_name, vo.members.map { |row| row.to_h.transform_keys(&:to_s).transform_values(&:to_s) }]
        end
      end

      def render(bluebook)
        rows = tables(bluebook).sort_by(&:first).map do |name, members|
          "      #{name.inspect} => [\n" +
            members.map { |row| "        #{row.inspect}.freeze" }.join(",\n") +
            "\n      ].freeze"
        end

        <<~RUBY
          #{HEADER}
          module Hecksagain
            module Vocabulary
              TABLES = {
          #{rows.join(",\n")}
              }.freeze

              # THE TERMS — the first field of each row, which for a
              # one-field vocabulary is the whole of it. Derived ONCE and
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
