module Hecks
  module Grammar
    module Evolve
      # Reading the KeywordSeed and ArgumentSeed value-object blocks out of the syntax tables as
      # text, and the row edits both kinds of row share. Extended onto `Hecks::Grammar::Evolve`.
      module Seeds
        # One `name: "value"` cell of a member row; the value may hold escaped quotes.
        CELL = /(\w+): "((?:[^"\\]|\\.)*)"/

        # Parses the Keyword one_of's member rows leniently off the text.
        def keyword_rows(path = nil)
          seed_rows(path, "KeywordSeed") do |row|
            { word: row["word"], context: row["context"],
              status: row.fetch("status", "admitted"), was: row["was"] }
          end
        end

        # Parses the ArgumentSeed's member rows leniently off the text.
        def argument_rows(path = nil)
          seed_rows(path, "ArgumentSeed") do |row|
            { keyword: row["keyword"], context: row["context"], at: row["at"].to_s,
              named: row["named"].to_s, kind: row["kind"], required: row["required"],
              fills: row["fills"].to_s, status: row.fetch("status", "admitted") }
          end
        end

        # @param path [String, Array<String>, nil] the files to read; nil reads every syntax table
        # @param name [String] the seed value object, `"KeywordSeed"` or `"ArgumentSeed"`
        # @yieldparam cells [Hash{String => String}] one member row's cells
        # @return [Array<Hash>] what the block makes of each member row
        # @raise [Refusal] when files were named and one declares no such value object
        def seed_rows(path, name)
          paths_for(path).flat_map do |candidate|
            blocks = seed_blocks(read_source(candidate), name)
            raise Refusal, "source declares no #{name} value object" if path && blocks.empty?

            blocks.flat_map { |block| block.scan(/^\s*member (.+)$/).map { |(cells)| yield cells.scan(CELL).to_h } }
          end
        end

        # Tells whether `line` is a KeywordSeed member row for (word, context).
        def member_row?(line, word, context)
          line =~ /^\s*member / && line.include?(%(word: "#{word}")) && line.include?(%(context: "#{context}"))
        end

        # Tells whether `line` is an ArgumentSeed row for this (keyword, context, at, named) tuple.
        def argument_row?(line, keyword, context, at, named)
          line =~ /^\s*member / &&
            line.include?(%(keyword: "#{keyword}")) && line.include?(%(context: "#{context}")) &&
            line.include?(%(at: "#{at}")) && line.include?(%(named: "#{named}"))
        end

        # The (keyword, context, at, named) identity tuple an argument row is keyed
        # by — wider than a Keyword row's two-field key.
        def argument_identity(row) = [row[:keyword], row[:context], row[:at], row[:named]]

        # Finds which syntax-table path declares a keyword row.
        def path_holding_keyword(word, context, paths = syntax_paths)
          paths.find do |candidate|
            keyword_blocks(read_source(candidate)).any? do |block|
              block.lines.any? { |line| member_row?(line, word, context) }
            end
          end || raise(Refusal, "#{context}.#{word} is not declared")
        end

        # Finds which syntax-table path declares an argument row.
        def path_holding_argument(keyword, context, at, named, paths = syntax_paths)
          paths.find do |candidate|
            argument_blocks(read_source(candidate)).any? do |block|
              block.lines.any? { |line| argument_row?(line, keyword, context, at, named) }
            end
          end || raise(Refusal, "#{context}.#{keyword}'s argument at #{at.inspect}/named #{named.inspect} is not declared")
        end

        # Picks the owning file for a new row; opens names the aggregate for a File-context word.
        def owner_path(context:, word:, opens: "", paths: syntax_paths)
          opening_path(context, opens, paths) || paths.find { |candidate| declares_context?(candidate, context) } ||
            raise(Refusal, "no aggregate-local syntax table owns context #{context.inspect} for #{word}")
        end

        # @return [String, nil] the file declaring the aggregate a File-context word opens
        def opening_path(context, opens, paths)
          return unless context == "File" && !opens.to_s.empty?

          paths.find { |candidate| read_source(candidate).match?(/^\s*aggregate "#{Regexp.escape(opens)}" do$/) }
        end

        def declares_context?(candidate, context)
          source = read_source(candidate)
          %w[KeywordSeed ArgumentSeed].any? do |seed|
            seed_blocks(source, seed).any? { |block| block.include?(%(context: "#{context}")) }
          end
        end

        # Appends a member row, at the end of the seed block owning `context`, as `proposed`;
        # whoever admits it may move it to its group.
        #
        # @param path [String] the file holding the block
        # @param context [String] the context whose block takes the row
        # @param seed [String] `"KeywordSeed"` or `"ArgumentSeed"`
        # @yieldparam indent [String] the whitespace the block's member rows start with
        # @yieldreturn [String] the new row, newline included
        def append_member(path, context, seed)
          source = read_source(path)
          block = seed_blocks(source, seed).find { |candidate| candidate.include?(%(context: "#{context}")) } ||
                  seed_block(source, seed, required: true)
          indent = block[/^(\s*)member /, 1] || "        "
          closing = block.rindex(/^\s*end\s*$/)
          write_source(path, source.sub(block, block[0...closing] + yield(indent) + block[closing..]))
        end

        # Rewrites, through the block, each line of the seed block holding the rows `matches` picks.
        #
        # @param path [String] the file holding the block
        # @param seed [String] `"KeywordSeed"` or `"ArgumentSeed"`
        # @param matches [#call] tells whether a line is one of the rows to rewrite
        # @param missing [String] the refusal when no row matches
        # @raise [Refusal] when no row matches
        def rewrite_member_rows(path, seed, matches, missing)
          source = read_source(path)
          block = seed_blocks(source, seed).find { |candidate| candidate.lines.any?(&matches) }
          raise Refusal, missing unless block

          updated = block.lines.map { |line| matches.call(line) ? yield(line) : line }.join
          write_source(path, source.sub(block, updated))
        end

        # Sets a row line's `status:` cell; admitted is the default and stays unspelled.
        def restatus(line, to)
          stripped = line.sub(/,\s*status: "[^"]*"/, "")
          to == "admitted" ? stripped : stripped.sub(/\n\z/, %(, status: "#{to}"\n))
        end

        # Every value_object "<name>" block's full source text, opener to closing end.
        def seed_blocks(source, name)
          opener = /^([ \t]*)value_object "#{Regexp.escape(name)}" do$/
          source.to_enum(:scan, opener).map do
            match = Regexp.last_match
            start = match.begin(0)
            closing = source.index(/^#{Regexp.escape(match[1])}end\s*$/, match.end(0))
            closing = source.index(/\n/, closing) + 1
            source[start...closing]
          end
        end

        # The first value_object "<name>" block's source text.
        def seed_block(source, name, required: false)
          block = seed_blocks(source, name).first
          unless block
            raise Refusal, "source declares no #{name} value object" if required

            return
          end
          block
        end

        # First `end` after the opener is the block's own — member rows sit bare (ADR 0025).
        def keyword_blocks(source) = seed_blocks(source, "KeywordSeed")

        # The first KeywordSeed block's source text.
        def keyword_block(source) = seed_block(source, "KeywordSeed", required: true)

        # ArgumentSeed blocks; see keyword_blocks for why the first bare end
        # after the opener is already the block's own.
        def argument_blocks(source) = seed_blocks(source, "ArgumentSeed")

        # The first ArgumentSeed block's source text.
        def argument_block(source) = seed_block(source, "ArgumentSeed", required: true)
      end
    end
  end
end
