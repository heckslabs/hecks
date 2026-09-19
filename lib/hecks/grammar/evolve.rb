module Hecks
  module Grammar
    # The file surgery under bin/evolve: reading and rewriting the
    # aggregate-local KeywordSeed/ArgumentSeed rows as text, so a
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

      # bin/evolve's own `--name value` flag reader. Only consumes the
      # next argv element as the value when that element doesn't itself
      # look like a flag — otherwise `--foo --bar` would swallow `--bar`
      # as `--foo`'s value (and `--bar` would then never be seen at
      # all), and a value-less `--foo` at the end of argv would bypass
      # whatever default `foo` promised instead of falling back to it.
      # @param argv [Array<String>] the command-line argument list to scan
      # @param name [String] the flag's name, without its leading `--`
      # @param default [String, nil] value to use when the flag is absent or has no value
      # @return [String, nil] the flag's value, or `default`
      def option(argv, name, default = nil)
        index = argv.index("--#{name}")
        return default unless index

        value = argv[index + 1]
        value.nil? || value.start_with?("-") ? default : value
      end

      # The snapshot/restore ceremony bin/evolve wraps every mutating
      # command in: read every `paths` file, run the block, and put
      # every file back exactly as it was if the block raises partway
      # through — `rename`'s keyword-row write followed by its
      # argument cascade across several files (`cascade_argument_rename`
      # above) included, not only a declared gate failing after the
      # block has already returned cleanly (bin/evolve's own `guarded`
      # still handles that half on its own, since it depends on running
      # the gate specs, not on anything this method knows about). A
      # clean return leaves the snapshots unused; the caller decides
      # from there whether the tree stands.
      #
      # @param paths [Array<String>] files to snapshot before running the block
      # @yield the mutating work to run, restored from snapshot if it raises
      # @return [Object] the block's result
      # @raise [StandardError] re-raises whatever the block raised, after restoring
      #   every snapshotted file
      def restore_on_raise(paths)
        snapshots = paths.to_h { |path| [path, File.read(path)] }
        yield
      rescue StandardError
        snapshots.each { |path, content| File.write(path, content) }
        raise
      end

      # Every syntax-table file declaring a `KeywordSeed` or `ArgumentSeed`
      # value object.
      #
      # @return [Array<String>] matching `.bluebook` file paths
      def syntax_paths
        Dir.glob(File.expand_path("../language/**/*.bluebook", __dir__)).select do |path|
          source = File.read(path)
          source.include?('value_object "KeywordSeed"') || source.include?('value_object "ArgumentSeed"')
        end
      end

      # Kept as a narrow compatibility door for callers deliberately doing
      # single-file surgery. Normal operation uses `syntax_paths` and discovers
      # the owning concept from the row itself.
      #
      # @return [String, nil] the first syntax-table path, or nil when there are none
      def syntax_path = syntax_paths.first

      # Resolves the file(s) a call should search or write.
      #
      # @param path [String, nil] an explicit single file, or nil for every syntax path
      # @return [Array<String>] `[path]` when given, else `syntax_paths`
      def paths_for(path) = path ? Array(path) : syntax_paths

      # The Keyword one_of's member rows, parsed leniently off the text —
      # enough to know each row's (word, context, status), which is all
      # the tool ever asks.
      #
      # @param path [String, nil] an explicit single file to read, or nil for every
      #   syntax path
      # @return [Array<Hash>] one Hash per member row, with `:word`, `:context`,
      #   `:status` (`"admitted"` when unspelled), and `:was` (nil unless renamed)
      # @raise [Refusal] if `path` is given and declares no `KeywordSeed` value object
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
      # `context` (or `opens`'s own aggregate, for a `File`-context word).
      #
      # @param word [String] the keyword's spelling
      # @param context [String] the grammar context the word is declared in
      # @param body [String] the keyword's body shape; `"none"` by default
      # @param inner [String] the keyword's inner shape, if any
      # @param opens [String] the aggregate concept a `File`-context word opens
      # @param fills [String] the field the keyword fills, if any
      # @param path [String, nil] an explicit single file to search/write, or nil to
      #   search every syntax path
      # @return [void]
      # @raise [Refusal] if `context`.`word` is already declared, or no syntax table
      #   owns `context`
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

        # At the end of the one_of — grouping by context is a courtesy of
        # the hand; a proposed row sits at the bottom until admission,
        # when whoever admits it may move it home.
        closing = block.rindex(/^\s*end\s*$/)
        updated = block[0...closing] + row + block[closing..]
        File.write(path, source.sub(block, updated))
      end

      # Rewrites a declared keyword row's `status:` cell in place.
      #
      # @param word [String] the keyword's spelling
      # @param context [String] the grammar context the word is declared in
      # @param to [String] the new status: `"proposed"`, `"admitted"`, `"deprecated"`,
      #   or `"retired"`
      # @param path [String, nil] an explicit single file to search/write, or nil to
      #   search every syntax path
      # @return [void]
      # @raise [Refusal] if `to` is not one of the four stations, or `context`.`word`
      #   is not declared
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
          # Admitted is the default and stays unspelled — only a word
          # entering or leaving the language carries its status.
          to == "admitted" ? stripped : stripped.sub(/\n\z/, %(, status: "#{to}"\n))
        end.join

        File.write(path, source.sub(block, updated))
      end

      # A rename respells the row's word and holds the old spelling in
      # `was:` — one hop only. Renaming an already-renamed word refuses
      # until the language grows real eras for its own words; renaming
      # onto a spelling the context already declares refuses too. The
      # word's Argument rows follow it — row-aware, not a blind
      # substitution (see `cascade_argument_rename`).
      #
      # @param word [String] the keyword's current spelling
      # @param context [String] the grammar context the word is declared in
      # @param to [String] the keyword's new spelling
      # @param path [String, nil] an explicit single file to search/write, or nil to
      #   search every syntax path
      # @return [void]
      # @raise [Refusal] if `context`.`word` is not declared, was already renamed once,
      #   or `to` is already declared in `context`
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

      # Tells whether `line` is a KeywordSeed member row for `(word, context)`.
      #
      # @param line [String] one raw source line
      # @param word [String] the keyword's spelling
      # @param context [String] the grammar context
      # @return [Boolean]
      def member_row?(line, word, context)
        line =~ /^\s*member / && line.include?(%(word: "#{word}")) && line.include?(%(context: "#{context}"))
      end

      # Finds which syntax-table path declares a keyword row.
      #
      # @param word [String] the keyword's spelling
      # @param context [String] the grammar context
      # @param paths [Array<String>] candidate syntax-table paths to search
      # @return [String] the path whose KeywordSeed declares `(word, context)`
      # @raise [Refusal] if no path in `paths` declares that row
      def path_holding_keyword(word, context, paths = syntax_paths)
        paths.find do |candidate|
          keyword_blocks(File.read(candidate)).any? { |block| block.lines.any? { |line| member_row?(line, word, context) } }
        end || raise(Refusal, "#{context}.#{word} is not declared")
      end

      # Finds which syntax-table path declares an argument row.
      #
      # @param keyword [String] the argument's owning keyword
      # @param context [String] the grammar context
      # @param at [String] the argument's positional slot, `""` for a named-only argument
      # @param named [String] the argument's keyword name, `""` for a positional-only argument
      # @param paths [Array<String>] candidate syntax-table paths to search
      # @return [String] the path whose ArgumentSeed declares this row
      # @raise [Refusal] if no path in `paths` declares that row
      def path_holding_argument(keyword, context, at, named, paths = syntax_paths)
        paths.find do |candidate|
          argument_blocks(File.read(candidate)).any? do |block|
            block.lines.any? do |line|
              argument_row?(line, keyword, context, at, named)
            end
          end
        end || raise(Refusal, "#{context}.#{keyword}'s argument at #{at.inspect}/named #{named.inspect} is not declared")
      end

      # A new row belongs wherever that context's existing rows live. File is
      # intentionally wider than one aggregate; for a new entry point, `opens`
      # identifies the aggregate concept whose file should own it.
      #
      # @param context [String] the grammar context a new row is being added to
      # @param word [String] the word being added, used only in the refusal message
      # @param opens [String] the aggregate concept a `File`-context word opens
      # @param paths [Array<String>] candidate syntax-table paths to search
      # @return [String] the path that should own the new row
      # @raise [Refusal] if no candidate path declares an existing row for `context`
      #   (and, for a `File` context with `opens` given, no path declares that aggregate)
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

      # Every `value_object "<name>"` block's full source text, from its
      # opener to its closing `end`.
      #
      # @param source [String] a `.bluebook` file's source text
      # @param name [String] the value object's name, such as `"KeywordSeed"`
      # @return [Array<String>] each matching block's raw source, including the
      #   opener and closing `end` lines
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

      # The first `value_object "<name>"` block's source text.
      #
      # @param source [String] a `.bluebook` file's source text
      # @param name [String] the value object's name, such as `"KeywordSeed"`
      # @param required [Boolean] whether a missing block should raise instead of
      #   returning nil
      # @return [String, nil] the block's raw source, or nil when absent and not
      #   `required`
      # @raise [Refusal] if `required` and `source` declares no such value object
      def seed_block(source, name, required: false)
        block = seed_blocks(source, name).first
        unless block
          raise Refusal, "source declares no #{name} value object" if required

          return
        end
        block
      end

      # From `value_object "KeywordSeed"` to its own closing `end` — `member`
      # rows sit bare now (S3, ADR 0025 — the `one_of do ... end` wrapper
      # is gone), so the first bare `end` line after the opener already
      # is the value object's own, the same fact the original one_of-
      # nested version of this method leaned on (nothing else nested
      # inside it either, before or after).
      # @param source [String] a `.bluebook` file's source text
      # @return [Array<String>] each KeywordSeed block's raw source
      def keyword_blocks(source) = seed_blocks(source, "KeywordSeed")

      # The first KeywordSeed block's source text.
      #
      # @param source [String] a `.bluebook` file's source text
      # @return [String] the first KeywordSeed block's raw source
      # @raise [Refusal] if `source` declares no KeywordSeed value object
      def keyword_block(source) = seed_block(source, "KeywordSeed", required: true)

      # ── the Argument rows — a word's own arguments, at last with tooling
      # of their own rather than the rename-only cascade above. A word may
      # carry several argument rows (one per position, one per named
      # kwarg), so identity here is the full (keyword, context, at, named)
      # tuple, not the two-field key a Keyword row answers to.

      # The ArgumentSeed's member rows, parsed leniently off the text.
      #
      # @param path [String, nil] an explicit single file to read, or nil for every
      #   syntax path
      # @return [Array<Hash>] one Hash per member row, with `:keyword`, `:context`,
      #   `:at`, `:named`, `:kind`, `:required`, `:fills`, and `:status`
      #   (`"admitted"` when unspelled)
      # @raise [Refusal] if `path` is given and declares no `ArgumentSeed` value object
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

      # `pairs_shape` — for a `pairs` argument that fills one field with a
      # whole key/value list rather than naming a field per pair (the
      # shape `Handler.dispatch`'s own `with:` already carries). Without
      # it, `spec/syntax_conformance_spec.rb` reads a pairs argument
      # naming a single field as a row that "names a single field, which
      # it cannot fill" — correctly, since the two shapes are genuinely
      # different and only one of them can be checked the same way.
      # @param keyword [String] the argument's owning keyword
      # @param context [String] the grammar context
      # @param kind [String] the argument's value kind
      # @param required [String] `"true"` or `"false"`, as text like every other cell
      # @param at [String] the argument's positional slot, `""` for a named-only argument
      # @param named [String] the argument's keyword name, `""` for a positional-only argument
      # @param fills [String] the field the argument fills, if any
      # @param pairs_shape [String, nil] the shape a `pairs` argument's key/value list
      #   fills, or nil when this argument is not a `pairs` argument
      # @param path [String, nil] an explicit single file to search/write, or nil to
      #   search every syntax path
      # @return [void]
      # @raise [Refusal] if this (keyword, context, at, named) row is already declared,
      #   or no syntax table owns `context`
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

      # Rewrites a declared argument row's `status:` cell in place.
      #
      # @param keyword [String] the argument's owning keyword
      # @param context [String] the grammar context
      # @param to [String] the new status: `"proposed"`, `"admitted"`, `"deprecated"`,
      #   or `"retired"`
      # @param at [String] the argument's positional slot, `""` for a named-only argument
      # @param named [String] the argument's keyword name, `""` for a positional-only argument
      # @param path [String, nil] an explicit single file to search/write, or nil to
      #   search every syntax path
      # @return [void]
      # @raise [Refusal] if `to` is not one of the four stations, or the row is not declared
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

      # Tells whether `line` is an ArgumentSeed member row for this
      # (keyword, context, at, named) tuple.
      #
      # @param line [String] one raw source line
      # @param keyword [String] the argument's owning keyword
      # @param context [String] the grammar context
      # @param at [String] the argument's positional slot
      # @param named [String] the argument's keyword name
      # @return [Boolean]
      def argument_row?(line, keyword, context, at, named)
        line =~ /^\s*member / &&
          line.include?(%(keyword: "#{keyword}")) && line.include?(%(context: "#{context}")) &&
          line.include?(%(at: "#{at}")) && line.include?(%(named: "#{named}"))
      end

      # The identity tuple an argument row is keyed by.
      #
      # @param row [Hash] an argument row, as `argument_rows` returns one
      # @return [Array(String, String, String, String)] the row's `(keyword, context,
      #   at, named)` identity tuple
      def argument_identity(row) = [row[:keyword], row[:context], row[:at], row[:named]]

      # The rename cascade, row-aware — only the rows that actually belong
      # to the renamed word, spelling updated in place, rather than a
      # blind `gsub` on every `keyword: "word",` substring in the file
      # (which a coincidentally-matching row elsewhere could have
      # corrupted, and which read nothing before writing).
      # @param keyword [String] the keyword whose argument rows follow its rename
      # @param context [String] the grammar context
      # @param to [String] the keyword's new spelling
      # @param path [String, nil] an explicit single file to search/write, or nil to
      #   search every syntax path
      # @return [void]
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

      # From `value_object "ArgumentSeed"` to its own closing `end` — see
      # `keyword_block`'s own comment for why the first bare `end` after
      # the opener is already the right one, now that `member` rows sit
      # bare (S3, ADR 0025).
      # @param source [String] a `.bluebook` file's source text
      # @return [Array<String>] each ArgumentSeed block's raw source
      def argument_blocks(source) = seed_blocks(source, "ArgumentSeed")

      # The first ArgumentSeed block's source text.
      #
      # @param source [String] a `.bluebook` file's source text
      # @return [String] the first ArgumentSeed block's raw source
      # @raise [Refusal] if `source` declares no ArgumentSeed value object
      def argument_block(source) = seed_block(source, "ArgumentSeed", required: true)
    end
  end
end
