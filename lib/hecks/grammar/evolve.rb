module Hecks
  module Grammar
    # File surgery under bin/evolve: reads and rewrites the aggregate-local
    # KeywordSeed/ArgumentSeed rows as text, preserving the table's own formatting.
    module Evolve
      class Refusal < StandardError; end

      module_function

      # Only consumes the next argv element as the value when it isn't itself
      # a flag, so `--foo --bar` doesn't swallow `--bar` as `--foo`'s value.
      def option(argv, name, default = nil)
        index = argv.index("--#{name}")
        return default unless index

        value = argv[index + 1]
        value.nil? || value.start_with?("-") ? default : value
      end

      # Snapshots `paths` before running the block and restores every file
      # if it raises, even partway through a multi-file write.
      def restore_on_raise(paths)
        snapshots = paths.to_h { |path| [path, File.read(path)] }
        yield
      rescue StandardError
        snapshots.each { |path, content| File.write(path, content) }
        raise
      end

      # Every syntax-table file declaring a KeywordSeed or ArgumentSeed value object.
      def syntax_paths
        Dir.glob(File.expand_path("../language/**/*.bluebook", __dir__)).select do |path|
          source = File.read(path)
          source.include?('value_object "KeywordSeed"') || source.include?('value_object "ArgumentSeed"')
        end
      end

      # Narrow compatibility door for single-file callers; syntax_paths is normal.
      def syntax_path = syntax_paths.first

      # Resolves the file(s) a call should search or write.
      def paths_for(path) = path ? Array(path) : syntax_paths

      # Parses the Keyword one_of's member rows leniently off the text.
      def keyword_rows(path = nil)
        paths_for(path).flat_map do |candidate|
          blocks = seed_blocks(File.read(candidate), "KeywordSeed")
          raise Refusal, "source declares no KeywordSeed value object" if path && blocks.empty?

          blocks.flat_map do |block|
            block.scan(/^\s*member (.+)$/).map do |(cells)|
              row = cells.scan(/(\w+): "((?:[^"\\]|\\.)*)"/).to_h
              { word: row["word"], context: row["context"],
                status: row.fetch("status", "admitted"), was: row["was"] }
            end
          end
        end
      end

      # Declares a new, proposed keyword row in the syntax table that owns
      # `context` (or the aggregate `opens` names, for a File-context word).
      def propose(word:, context:, body: "none", inner: "", opens: "", fills: "", path: nil)
        if keyword_rows(path).any? do |row|
          row[:word] == word && row[:context] == context
        end
          raise Refusal,
                "#{context}.#{word} is already declared — one row per (word, context, form)"
        end

        path = owner_path(context: context, word: word, opens: opens, paths: paths_for(path))
        source = File.read(path)
        block  = keyword_blocks(source).find { |candidate| candidate.include?(%(context: "#{context}")) } || keyword_block(source)
        indent = block[/^(\s*)member /, 1] || "        "
        row = %(#{indent}member word: "#{word}", context: "#{context}", body: "#{body}", ) +
              %(inner: "#{inner}", opens: "#{opens}", fills: "#{fills}", status: "proposed"\n)

        # Appended at the end; whoever admits it may move it to its group.
        closing = block.rindex(/^\s*end\s*$/)
        updated = block[0...closing] + row + block[closing..]
        File.write(path, source.sub(block, updated))
      end

      # Rewrites a declared keyword row's status: cell in place.
      def set_status(word:, context:, to:, path: nil)
        raise Refusal, "#{to.inspect} is not a station a word's life admits" unless %w[proposed admitted deprecated
                                                                                       retired].include?(to)

        path = path_holding_keyword(word, context, paths_for(path))
        source = File.read(path)
        block  = keyword_blocks(source).find { |candidate| candidate.lines.any? { |line| member_row?(line, word, context) } }
        rows   = block.lines.select { |line| member_row?(line, word, context) }
        raise Refusal, "#{context}.#{word} is not declared" if rows.empty?

        updated = block.lines.map do |line|
          next line unless member_row?(line, word, context)

          stripped = line.sub(/,\s*status: "[^"]*"/, "")
          # Admitted is the default and stays unspelled in the row.
          to == "admitted" ? stripped : stripped.sub(/\n\z/, %(, status: "#{to}"\n))
        end.join

        File.write(path, source.sub(block, updated))
      end

      # Respells a keyword row (was: holds the old spelling) — one hop only;
      # its Argument rows follow, row-aware (see cascade_argument_rename).
      def rename(word:, context:, to:, path: nil)
        row = keyword_rows(path).find { |r| r[:word] == word && r[:context] == context }
        raise Refusal, "#{context}.#{word} is not declared" unless row
        raise Refusal, "#{context}.#{word} was already #{row[:was]} — one rename hop, then eras" if row[:was]
        if keyword_rows(path).any? do |r|
          r[:word] == to && r[:context] == context
        end
          raise Refusal,
                "#{context}.#{to} is already declared — a rename cannot land on a living word"
        end

        paths = paths_for(path)
        path = path_holding_keyword(word, context, paths)
        source = File.read(path)
        block  = keyword_blocks(source).find { |candidate| candidate.lines.any? { |line| member_row?(line, word, context) } }
        updated = block.lines.map do |line|
          next line unless member_row?(line, word, context)

          line.sub(%(word: "#{word}"), %(word: "#{to}"))
              .sub(/\n\z/, %(, was: "#{word}"\n))
        end.join
        source = source.sub(block, updated)
        File.write(path, source)

        cascade_argument_rename(keyword: word, context: context, to: to, path: paths)
      end

      # Tells whether `line` is a KeywordSeed member row for (word, context).
      def member_row?(line, word, context)
        line =~ /^\s*member / && line.include?(%(word: "#{word}")) && line.include?(%(context: "#{context}"))
      end

      # Finds which syntax-table path declares a keyword row.
      def path_holding_keyword(word, context, paths = syntax_paths)
        paths.find do |candidate|
          keyword_blocks(File.read(candidate)).any? { |block| block.lines.any? { |line| member_row?(line, word, context) } }
        end || raise(Refusal, "#{context}.#{word} is not declared")
      end

      # Finds which syntax-table path declares an argument row.
      def path_holding_argument(keyword, context, at, named, paths = syntax_paths)
        paths.find do |candidate|
          argument_blocks(File.read(candidate)).any? do |block|
            block.lines.any? do |line|
              argument_row?(line, keyword, context, at, named)
            end
          end
        end || raise(Refusal, "#{context}.#{keyword}'s argument at #{at.inspect}/named #{named.inspect} is not declared")
      end

      # Picks the owning file for a new row; opens names the aggregate for a File-context word.
      def owner_path(context:, word:, opens: "", paths: syntax_paths)
        if context == "File" && !opens.to_s.empty?
          aggregate_path = paths.find { |candidate| File.read(candidate).match?(/^\s*aggregate "#{Regexp.escape(opens)}" do$/) }
          return aggregate_path if aggregate_path
        end

        paths.find do |candidate|
          source = File.read(candidate)
          %w[KeywordSeed ArgumentSeed].any? do |seed|
            seed_blocks(source, seed).any? { |block| block.include?(%(context: "#{context}")) }
          end
        end || raise(Refusal, "no aggregate-local syntax table owns context #{context.inspect} for #{word}")
      end

      # Every value_object "<name>" block's full source text, opener to closing end.
      def seed_blocks(source, name)
        opener = /^([ \t]*)value_object "#{Regexp.escape(name)}" do$/
        source.to_enum(:scan, opener).map do
          match = Regexp.last_match
          start = match.begin(0)
          indent = match[1]
          closing = source.index(/^#{Regexp.escape(indent)}end\s*$/, match.end(0))
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

      # Parses the ArgumentSeed's member rows leniently off the text.
      def argument_rows(path = nil)
        paths_for(path).flat_map do |candidate|
          blocks = seed_blocks(File.read(candidate), "ArgumentSeed")
          raise Refusal, "source declares no ArgumentSeed value object" if path && blocks.empty?

          blocks.flat_map do |block|
            block.scan(/^\s*member (.+)$/).map do |(cells)|
              row = cells.scan(/(\w+): "((?:[^"\\]|\\.)*)"/).to_h
              { keyword: row["keyword"], context: row["context"], at: row["at"].to_s,
                named: row["named"].to_s, kind: row["kind"], required: row["required"],
                fills: row["fills"].to_s, status: row.fetch("status", "admitted") }
            end
          end
        end
      end

      # Declares a new, proposed argument row; pairs_shape marks a `pairs`
      # argument that fills a whole key/value list, not a single field.
      def propose_argument(keyword:, context:, kind:, required: "false", at: "", named: "", fills: "",
                           pairs_shape: nil, path: nil)
        if argument_rows(path).any? { |r| argument_identity(r) == [keyword, context, at, named] }
          raise Refusal, "#{context}.#{keyword}'s argument at #{at.inspect}/named #{named.inspect} is " \
                         "already declared — one row per (keyword, context, at, named)"
        end

        path = owner_path(context: context, word: keyword, paths: paths_for(path))
        source = File.read(path)
        block  = argument_blocks(source).find do |candidate|
          candidate.include?(%(context: "#{context}"))
        end || argument_block(source)
        indent = block[/^(\s*)member /, 1] || "        "
        shape = pairs_shape.to_s.empty? ? "" : %(pairs_shape: "#{pairs_shape}", )
        row = %(#{indent}member keyword: "#{keyword}", context: "#{context}", at: "#{at}", ) +
              %(named: "#{named}", kind: "#{kind}", required: "#{required}", fills: "#{fills}", ) +
              shape + %(status: "proposed"\n)

        closing = block.rindex(/^\s*end\s*$/)
        updated = block[0...closing] + row + block[closing..]
        File.write(path, source.sub(block, updated))
      end

      # Rewrites a declared argument row's status: cell in place.
      def set_argument_status(keyword:, context:, to:, at: "", named: "", path: nil)
        raise Refusal, "#{to.inspect} is not a station an argument's life admits" unless %w[proposed admitted deprecated
                                                                                            retired].include?(to)

        path = path_holding_argument(keyword, context, at, named, paths_for(path))
        source = File.read(path)
        block  = argument_blocks(source).find do |candidate|
          candidate.lines.any? do |line|
            argument_row?(line, keyword, context, at, named)
          end
        end
        rows = block.lines.select { |line| argument_row?(line, keyword, context, at, named) }
        if rows.empty?
          raise Refusal, "#{context}.#{keyword}'s argument at #{at.inspect}/named #{named.inspect} is not " \
                         "declared"
        end

        updated = block.lines.map do |line|
          next line unless argument_row?(line, keyword, context, at, named)

          stripped = line.sub(/,\s*status: "[^"]*"/, "")
          to == "admitted" ? stripped : stripped.sub(/\n\z/, %(, status: "#{to}"\n))
        end.join

        File.write(path, source.sub(block, updated))
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

      # Row-aware rename cascade — updates only the argument rows that belong
      # to the renamed keyword, not a blind gsub across the file.
      def cascade_argument_rename(keyword:, context:, to:, path: nil)
        paths_for(path).each do |candidate|
          source = File.read(candidate)
          original = source
          argument_blocks(source).each do |block|
            updated = block.lines.map do |line|
              next line unless line =~ /^\s*member / &&
                               line.include?(%(keyword: "#{keyword}")) && line.include?(%(context: "#{context}"))

              line.sub(%(keyword: "#{keyword}"), %(keyword: "#{to}"))
            end.join
            source = source.sub(block, updated) if updated != block
          end
          File.write(candidate, source) if source != original
        end
      end

      # ArgumentSeed blocks; see keyword_blocks for why the first bare end
      # after the opener is already the block's own.
      def argument_blocks(source) = seed_blocks(source, "ArgumentSeed")

      # The first ArgumentSeed block's source text.
      def argument_block(source) = seed_block(source, "ArgumentSeed", required: true)
    end
  end
end
