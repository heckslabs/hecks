module Hecksagain
  module Grammar
    # The file surgery under bin/evolve: reading and rewriting the
    # aggregate-local KeywordSeed/ArgumentSeed rows as TEXT, so a
    # proposed word enters the table exactly as a hand would write it
    # and an admitted one loses its ceremony (an absent status reads as
    # admitted — the grown-column convention).
    #
    # Text, not IR, on purpose: the syntax table is source, its comments
    # and grouping are part of the declaration, and a rewrite that
    # round-tripped it through the IR would flatten both. Everything
    # here touches only bare `member ` lines inside Keyword's own body
    # (S3, ADR 0025 — no `one_of do ... end` wrapper anymore) and leaves
    # every other byte alone.
    module Evolve
      class Refusal < StandardError; end

      module_function

      def syntax_paths
        Dir.glob(File.expand_path("../language/**/*.bluebook", __dir__)).select do |path|
          source = File.read(path)
          source.include?('value_object "KeywordSeed"') || source.include?('value_object "ArgumentSeed"')
        end
      end

      # Kept as a narrow compatibility door for callers deliberately doing
      # single-file surgery. Normal operation uses `syntax_paths` and discovers
      # the owning concept from the row itself.
      def syntax_path = syntax_paths.first

      def paths_for(path) = path ? Array(path) : syntax_paths

      # The Keyword one_of's member rows, parsed leniently off the text —
      # enough to know each row's (word, context, status), which is all
      # the tool ever asks.
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

      def propose(word:, context:, body: "none", inner: "", opens: "", fills: "", path: nil)
        raise Refusal, "#{context}.#{word} is already declared — one row per (word, context, form)" if keyword_rows(path).any? { |row| row[:word] == word && row[:context] == context }

        path = owner_path(context: context, word: word, opens: opens, paths: paths_for(path))
        source = File.read(path)
        block  = keyword_blocks(source).find { |candidate| candidate.include?(%(context: "#{context}")) } || keyword_block(source)
        indent = block[/^(\s*)member /, 1] || "        "
        row = %(#{indent}member word: "#{word}", context: "#{context}", body: "#{body}", ) +
              %(inner: "#{inner}", opens: "#{opens}", fills: "#{fills}", status: "proposed"\n)

        # At the END of the one_of — grouping by context is a courtesy of
        # the hand; a proposed row sits at the bottom until admission,
        # when whoever admits it may move it home.
        closing = block.rindex(/^\s*end\s*$/)
        updated = block[0...closing] + row + block[closing..]
        File.write(path, source.sub(block, updated))
      end

      def set_status(word:, context:, to:, path: nil)
        raise Refusal, "#{to.inspect} is not a station a word's life admits" unless %w[proposed admitted deprecated retired].include?(to)

        path = path_holding_keyword(word, context, paths_for(path))
        source = File.read(path)
        block  = keyword_blocks(source).find { |candidate| candidate.lines.any? { |line| member_row?(line, word, context) } }
        rows   = block.lines.select { |line| member_row?(line, word, context) }
        raise Refusal, "#{context}.#{word} is not declared" if rows.empty?

        updated = block.lines.map do |line|
          next line unless member_row?(line, word, context)

          stripped = line.sub(/,\s*status: "[^"]*"/, "")
          # Admitted is the default and stays UNSPELLED — only a word
          # entering or leaving the language carries its status.
          to == "admitted" ? stripped : stripped.sub(/\n\z/, %(, status: "#{to}"\n))
        end.join

        File.write(path, source.sub(block, updated))
      end

      # A rename respells the row's word and holds the old spelling in
      # `was:` — one hop only. Renaming an already-renamed word refuses
      # until the language grows real eras for its own words; renaming
      # onto a spelling the context already declares refuses too. The
      # word's Argument rows follow it — row-aware now, not the blind
      # substitution this used to be (see `cascade_argument_rename`).
      def rename(word:, context:, to:, path: nil)
        row = keyword_rows(path).find { |r| r[:word] == word && r[:context] == context }
        raise Refusal, "#{context}.#{word} is not declared" unless row
        raise Refusal, "#{context}.#{word} was already #{row[:was]} — one rename hop, then eras" if row[:was]
        raise Refusal, "#{context}.#{to} is already declared — a rename cannot land on a living word" if keyword_rows(path).any? { |r| r[:word] == to && r[:context] == context }

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

      def member_row?(line, word, context)
        line =~ /^\s*member / && line.include?(%(word: "#{word}")) && line.include?(%(context: "#{context}"))
      end

      def path_holding_keyword(word, context, paths = syntax_paths)
        paths.find do |candidate|
          keyword_blocks(File.read(candidate)).any? { |block| block.lines.any? { |line| member_row?(line, word, context) } }
        end || raise(Refusal, "#{context}.#{word} is not declared")
      end

      def path_holding_argument(keyword, context, at, named, paths = syntax_paths)
        paths.find do |candidate|
          argument_blocks(File.read(candidate)).any? { |block| block.lines.any? { |line| argument_row?(line, keyword, context, at, named) } }
        end || raise(Refusal, "#{context}.#{keyword}'s argument at #{at.inspect}/named #{named.inspect} is not declared")
      end

      # A new row belongs wherever that context's existing rows live. File is
      # intentionally wider than one aggregate; for a new entry point, `opens`
      # identifies the aggregate concept whose file should own it.
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

      def seed_block(source, name, required: false)
        block = seed_blocks(source, name).first
        unless block
          raise Refusal, "source declares no #{name} value object" if required

          return
        end
        block
      end

      # From `value_object "KeywordSeed"` to ITS OWN closing `end` — `member`
      # rows sit bare now (S3, ADR 0025 — the `one_of do ... end` wrapper
      # is gone), so the first bare `end` line after the opener already
      # IS the value object's own, the same fact the original one_of-
      # nested version of this method leaned on (nothing else nested
      # inside it either, before or after).
      def keyword_blocks(source) = seed_blocks(source, "KeywordSeed")
      def keyword_block(source) = seed_block(source, "KeywordSeed", required: true)

      # ── the Argument rows — a word's own arguments, at last with tooling
      # of their own rather than the rename-only cascade above. A word may
      # carry SEVERAL argument rows (one per position, one per named
      # kwarg), so identity here is the full (keyword, context, at, named)
      # tuple, not the two-field key a Keyword row answers to.

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

      # `pairs_shape` — for a `pairs` argument that fills ONE field with a
      # whole key/value list rather than naming a field per pair (the
      # shape `Handler.dispatch`'s own `with:` already carries). Without
      # it, `spec/syntax_conformance_spec.rb` reads a pairs argument
      # naming a single field as a row that "names a single field, which
      # it cannot fill" — correctly, since the two shapes are genuinely
      # different and only one of them can be checked the same way.
      def propose_argument(keyword:, context:, kind:, required: "false", at: "", named: "", fills: "",
                           pairs_shape: nil, path: nil)
        if argument_rows(path).any? { |r| argument_identity(r) == [keyword, context, at, named] }
          raise Refusal, "#{context}.#{keyword}'s argument at #{at.inspect}/named #{named.inspect} is " \
                         "already declared — one row per (keyword, context, at, named)"
        end

        path = owner_path(context: context, word: keyword, paths: paths_for(path))
        source = File.read(path)
        block  = argument_blocks(source).find { |candidate| candidate.include?(%(context: "#{context}")) } || argument_block(source)
        indent = block[/^(\s*)member /, 1] || "        "
        shape = pairs_shape.to_s.empty? ? "" : %(pairs_shape: "#{pairs_shape}", )
        row = %(#{indent}member keyword: "#{keyword}", context: "#{context}", at: "#{at}", ) +
              %(named: "#{named}", kind: "#{kind}", required: "#{required}", fills: "#{fills}", ) +
              shape + %(status: "proposed"\n)

        closing = block.rindex(/^\s*end\s*$/)
        updated = block[0...closing] + row + block[closing..]
        File.write(path, source.sub(block, updated))
      end

      def set_argument_status(keyword:, context:, to:, at: "", named: "", path: nil)
        raise Refusal, "#{to.inspect} is not a station an argument's life admits" unless %w[proposed admitted deprecated retired].include?(to)

        path = path_holding_argument(keyword, context, at, named, paths_for(path))
        source = File.read(path)
        block  = argument_blocks(source).find { |candidate| candidate.lines.any? { |line| argument_row?(line, keyword, context, at, named) } }
        rows   = block.lines.select { |line| argument_row?(line, keyword, context, at, named) }
        raise Refusal, "#{context}.#{keyword}'s argument at #{at.inspect}/named #{named.inspect} is not " \
                       "declared" if rows.empty?

        updated = block.lines.map do |line|
          next line unless argument_row?(line, keyword, context, at, named)

          stripped = line.sub(/,\s*status: "[^"]*"/, "")
          to == "admitted" ? stripped : stripped.sub(/\n\z/, %(, status: "#{to}"\n))
        end.join

        File.write(path, source.sub(block, updated))
      end

      def argument_row?(line, keyword, context, at, named)
        line =~ /^\s*member / &&
          line.include?(%(keyword: "#{keyword}")) && line.include?(%(context: "#{context}")) &&
          line.include?(%(at: "#{at}")) && line.include?(%(named: "#{named}"))
      end

      def argument_identity(row) = [row[:keyword], row[:context], row[:at], row[:named]]

      # The rename cascade, ROW-AWARE — only the rows that actually belong
      # to the renamed word, spelling updated in place, rather than a
      # blind `gsub` on every `keyword: "word",` substring in the file
      # (which a coincidentally-matching row elsewhere could have
      # corrupted, and which read nothing before writing).
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

      # From `value_object "ArgumentSeed"` to ITS OWN closing `end` — see
      # `keyword_block`'s own comment for why the first bare `end` after
      # the opener is already the right one, now that `member` rows sit
      # bare (S3, ADR 0025).
      def argument_blocks(source) = seed_blocks(source, "ArgumentSeed")
      def argument_block(source) = seed_block(source, "ArgumentSeed", required: true)
    end
  end
end
