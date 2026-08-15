module Hecksagain
  module Grammar
    # The file surgery under bin/evolve: reading and rewriting the
    # Keyword rows of language/bluebook/syntax.bluebook as TEXT, so a
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

      def syntax_path
        File.expand_path("../language/bluebook/syntax.bluebook", __dir__)
      end

      # The Keyword one_of's member rows, parsed leniently off the text —
      # enough to know each row's (word, context, status), which is all
      # the tool ever asks.
      def keyword_rows(path = syntax_path)
        block = keyword_block(File.read(path))
        block.scan(/^\s*member (.+)$/).map do |(cells)|
          row = cells.scan(/(\w+): "((?:[^"\\]|\\.)*)"/).to_h
          { word: row["word"], context: row["context"],
            status: row.fetch("status", "admitted"), was: row["was"] }
        end
      end

      def propose(word:, context:, body: "none", inner: "", opens: "", fills: "", path: syntax_path)
        if keyword_rows(path).any? { |row| row[:word] == word && row[:context] == context }
          raise Refusal, "#{context}.#{word} is already declared — one row per (word, context, form)"
        end

        source = File.read(path)
        block  = keyword_block(source)
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

      def set_status(word:, context:, to:, path: syntax_path)
        unless %w[proposed admitted deprecated retired].include?(to)
          raise Refusal, "#{to.inspect} is not a station a word's life admits"
        end

        source = File.read(path)
        block  = keyword_block(source)
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
      def rename(word:, context:, to:, path: syntax_path)
        row = keyword_rows(path).find { |r| r[:word] == word && r[:context] == context }
        raise Refusal, "#{context}.#{word} is not declared" unless row
        raise Refusal, "#{context}.#{word} was already #{row[:was]} — one rename hop, then eras" if row[:was]
        if keyword_rows(path).any? { |r| r[:word] == to && r[:context] == context }
          raise Refusal, "#{context}.#{to} is already declared — a rename cannot land on a living word"
        end

        source = File.read(path)
        block  = keyword_block(source)
        updated = block.lines.map do |line|
          next line unless member_row?(line, word, context)

          line.sub(%(word: "#{word}"), %(word: "#{to}"))
              .sub(/\n\z/, %(, was: "#{word}"\n))
        end.join
        source = source.sub(block, updated)
        File.write(path, source)

        cascade_argument_rename(keyword: word, context: context, to: to, path: path)
      end

      def member_row?(line, word, context)
        line =~ /^\s*member / && line.include?(%(word: "#{word}")) && line.include?(%(context: "#{context}"))
      end

      # From `value_object "Keyword"` to ITS OWN closing `end` — `member`
      # rows sit bare now (S3, ADR 0025 — the `one_of do ... end` wrapper
      # is gone), so the first bare `end` line after the opener already
      # IS the value object's own, the same fact the original one_of-
      # nested version of this method leaned on (nothing else nested
      # inside it either, before or after).
      def keyword_block(source)
        start = source.index(/^\s*value_object "Keyword" do$/)
        raise Refusal, "syntax.bluebook declares no Keyword value object" unless start

        closing = source.index(/^\s*end\s*$/, start)
        closing = source.index(/\n/, closing) + 1
        source[start...closing]
      end

      # ── the Argument rows — a word's own arguments, at last with tooling
      # of their own rather than the rename-only cascade above. A word may
      # carry SEVERAL argument rows (one per position, one per named
      # kwarg), so identity here is the full (keyword, context, at, named)
      # tuple, not the two-field key a Keyword row answers to.

      def argument_rows(path = syntax_path)
        block = argument_block(File.read(path))
        block.scan(/^\s*member (.+)$/).map do |(cells)|
          row = cells.scan(/(\w+): "((?:[^"\\]|\\.)*)"/).to_h
          { keyword: row["keyword"], context: row["context"], at: row["at"].to_s,
            named: row["named"].to_s, kind: row["kind"], required: row["required"],
            fills: row["fills"].to_s, status: row.fetch("status", "admitted") }
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
                           pairs_shape: nil, path: syntax_path)
        if argument_rows(path).any? { |r| argument_identity(r) == [keyword, context, at, named] }
          raise Refusal, "#{context}.#{keyword}'s argument at #{at.inspect}/named #{named.inspect} is " \
                        "already declared — one row per (keyword, context, at, named)"
        end

        source = File.read(path)
        block  = argument_block(source)
        indent = block[/^(\s*)member /, 1] || "        "
        shape = pairs_shape.to_s.empty? ? "" : %(pairs_shape: "#{pairs_shape}", )
        row = %(#{indent}member keyword: "#{keyword}", context: "#{context}", at: "#{at}", ) +
              %(named: "#{named}", kind: "#{kind}", required: "#{required}", fills: "#{fills}", ) +
              shape + %(status: "proposed"\n)

        closing = block.rindex(/^\s*end\s*$/)
        updated = block[0...closing] + row + block[closing..]
        File.write(path, source.sub(block, updated))
      end

      def set_argument_status(keyword:, context:, to:, at: "", named: "", path: syntax_path)
        unless %w[proposed admitted deprecated retired].include?(to)
          raise Refusal, "#{to.inspect} is not a station an argument's life admits"
        end

        source = File.read(path)
        block  = argument_block(source)
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
      def cascade_argument_rename(keyword:, context:, to:, path: syntax_path)
        source = File.read(path)
        block  = argument_block(source)
        updated = block.lines.map do |line|
          next line unless line =~ /^\s*member / &&
                           line.include?(%(keyword: "#{keyword}")) && line.include?(%(context: "#{context}"))

          line.sub(%(keyword: "#{keyword}"), %(keyword: "#{to}"))
        end.join
        File.write(path, source.sub(block, updated))
      end

      # From `value_object "Argument"` to ITS OWN closing `end` — see
      # `keyword_block`'s own comment for why the first bare `end` after
      # the opener is already the right one, now that `member` rows sit
      # bare (S3, ADR 0025).
      def argument_block(source)
        start = source.index(/^\s*value_object "Argument" do$/)
        raise Refusal, "syntax.bluebook declares no Argument value object" unless start

        closing = source.index(/^\s*end\s*$/, start)
        closing = source.index(/\n/, closing) + 1
        source[start...closing]
      end
    end
  end
end
