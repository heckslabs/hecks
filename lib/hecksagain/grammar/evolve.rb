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
    # here touches only `member ` lines inside Keyword's one_of block
    # and leaves every other byte alone.
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
            status: row.fetch("status", "admitted") }
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

      def member_row?(line, word, context)
        line =~ /^\s*member / && line.include?(%(word: "#{word}")) && line.include?(%(context: "#{context}"))
      end

      # From `value_object "Keyword"` to the end of its one_of block —
      # the only region this module may touch.
      def keyword_block(source)
        start = source.index(/^\s*value_object "Keyword" do$/)
        raise Refusal, "syntax.bluebook declares no Keyword value object" unless start

        one_of = source.index(/^\s*one_of do$/, start)
        closing = source.index(/^\s*end\s*$/, one_of)
        closing = source.index(/\n/, closing) + 1
        source[start...closing]
      end
    end
  end
end
