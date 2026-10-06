module Hecks
  module Grammar
    module Evolve
      # The edits to KeywordSeed rows: declare a word, move it through its stations, respell it.
      # Extended onto `Hecks::Grammar::Evolve`.
      module Keywords
        # What `propose` fills in for the cells a caller leaves out.
        KEYWORD_DEFAULTS = { body: "none", inner: "", opens: "", fills: "" }.freeze

        # Declares a new, proposed keyword row in the syntax table that owns
        # `context` (or the aggregate `opens` names, for a File-context word).
        #
        # @param word [String] the keyword
        # @param context [String] the context the keyword is written in
        # @param fields [Hash] optionally `body:`, `inner:`, `opens:` and `fills:` cells, and
        #   `path:` naming the file(s) to edit
        # @raise [Refusal] when the row is already declared, or no table owns the context
        # @raise [ArgumentError] for any other keyword
        def propose(word:, context:, **fields)
          check_fields!(fields, KEYWORD_DEFAULTS.keys + [:path])
          cells = KEYWORD_DEFAULTS.merge(fields.except(:path))
          refuse_declared_keyword!(word, context, fields[:path])
          path = owner_path(context: context, word: word, opens: cells[:opens], paths: paths_for(fields[:path]))
          append_member(path, context, "KeywordSeed") { |indent| keyword_member(indent, word, context, cells) }
        end

        # @raise [Refusal] when a row for this word and context already exists
        def refuse_declared_keyword!(word, context, path)
          return unless keyword_rows(path).any? { |row| row[:word] == word && row[:context] == context }

          raise Refusal, "#{context}.#{word} is already declared — one row per (word, context, form)"
        end

        # @return [String] the new member row, spelled with `indent`
        def keyword_member(indent, word, context, cells)
          %(#{indent}member word: "#{word}", context: "#{context}", body: "#{cells[:body]}", ) +
            %(inner: "#{cells[:inner]}", opens: "#{cells[:opens]}", fills: "#{cells[:fills]}", status: "proposed"\n)
        end

        # Rewrites a declared keyword row's status: cell in place.
        def set_status(word:, context:, to:, path: nil)
          raise Refusal, "#{to.inspect} is not a station a word's life admits" unless STATIONS.include?(to)

          rewrite_member_rows(path_holding_keyword(word, context, paths_for(path)), "KeywordSeed",
                              ->(line) { member_row?(line, word, context) },
                              "#{context}.#{word} is not declared") { |line| restatus(line, to) }
        end

        # Respells a keyword row (was: holds the old spelling) — one hop only;
        # its Argument rows follow, row-aware (see cascade_argument_rename).
        def rename(word:, context:, to:, path: nil)
          refuse_rename!(word, context, to, path)
          paths = paths_for(path)
          rewrite_member_rows(path_holding_keyword(word, context, paths), "KeywordSeed",
                              ->(line) { member_row?(line, word, context) },
                              "#{context}.#{word} is not declared") do |line|
            line.sub(%(word: "#{word}"), %(word: "#{to}")).sub(/\n\z/, %(, was: "#{word}"\n))
          end
          cascade_argument_rename(keyword: word, context: context, to: to, path: paths)
        end

        # @raise [Refusal] unless the word is declared, not already respelled, and the new
        #   spelling is free in its context
        def refuse_rename!(word, context, to, path)
          rows = keyword_rows(path)
          row = rows.find { |r| r[:word] == word && r[:context] == context }
          raise Refusal, "#{context}.#{word} is not declared" unless row
          raise Refusal, "#{context}.#{word} was already #{row[:was]} — one rename hop, then eras" if row[:was]

          refuse_living_word!(rows, context, to)
        end

        def refuse_living_word!(rows, context, to)
          return unless rows.any? { |r| r[:word] == to && r[:context] == context }

          raise Refusal, "#{context}.#{to} is already declared — a rename cannot land on a living word"
        end
      end
    end
  end
end
