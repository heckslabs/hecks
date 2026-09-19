require_relative "../bluebook/meta_validator"
require_relative "../naming"

module Hecks
  module Doc
    # The DSL reference, projected from the language's own Syntax chapter
    # — the same Keyword/Argument rows the conformance specs hold equal
    # to the live builders. Nothing here is described twice: the tables
    # come from the declaration, the prose is hand-written between
    # markers the generator preserves, and the golden spec refuses a
    # tree where the two have drifted.
    #
    # Regenerate with bin/reference. A new word arrives with a TODO
    # sentinel; the coverage gate refuses to let an admitted word ship
    # undocumented; prose for a word the language no longer declares is
    # a hard error naming its orphans — deleting someone's writing is a
    # human's decision.
    module Reference
      GENERATED_END = "<!-- generated:end -->".freeze
      TODO_SENTINEL = "<!-- TODO: document this word -->".freeze

      # A page's own hand-written opening, harvested under a key no word
      # can ever collide with (words are strings off the Syntax chapter;
      # this is a Symbol). It exists so a page can boot once — load a real
      # corpus chapter, wire its hexagon — and have every word's example
      # below run against that single boot, the way a guide's opening
      # `ruby boot` block already does. Without it each word would have to
      # stand up its own domain, and 105 invented chapters would collide
      # on the facade constants `Surface.install` never uninstalls.
      PREAMBLE = :preamble

      module_function

      # The marker opening one word's generated region.
      #
      # @param word [String, Symbol, #to_s] the word this section documents
      # @return [String] the HTML comment marking that word's generated region open
      def generated_begin(word) = "<!-- generated:begin word=#{word} -->"

      # Keyed by region rather than by word — the same marker convention,
      # used for the parts of a page that are not about one word: a
      # page's generated lede here, README's generated indexes below.
      #
      # @param id [String, Symbol, #to_s] the region's id, such as `"page"` or `"tools"`
      # @return [String] the HTML comment marking that region's generated region open
      def region_begin(id) = "<!-- generated:begin id=#{id} -->"

      # The language's own Syntax aggregate, read off the judged grammar chapter.
      #
      # @return [Bluebook::Aggregate, nil] the Syntax aggregate, or nil if the
      #   grammar's Bluebook chapter declares none by that name
      def syntax
        meta = Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")
        meta.aggregates.find { |aggregate| aggregate.hecks_name == "Syntax" }
      end

      # Reads one closed-set value object's declared members off the Syntax
      # aggregate, as string-valued Hashes.
      #
      # @param name [String, Symbol, #to_s] the value object's `hecks_name`,
      #   such as `"Keyword"`
      # @return [Array<Hash{Symbol => String}>] each declared member's fields,
      #   values stringified
      def rows(name)
        syntax.value_objects.find { |vo| vo.hecks_name == name }
              .members.map { |row| row.to_h.transform_values(&:to_s) }
      end

      # S14, ADR 0026 — Keyword/Argument are genuine entities of Syntax
      # now, dispatched (not merely declared) so their own `status`
      # really is a lifecycle. `SyntaxBoot.call` discovers the static
      # aggregate-local seed rows (`KeywordSeed`/`ArgumentSeed`), dispatches each
      # one through the real admission/lifecycle door, and hands back the
      # same shape `rows`, above, already produces — nothing below this
      # needed to change.
      #
      # This module holds no separate `@keywords ||=` memo of its own —
      # delegates straight through to `SyntaxBoot.call`'s own cache
      # (keyed on the grammar registry's own chapter set — see its
      # comment) rather than shadowing it. A second, local cache on top
      # of that one would double-cache with no way to invalidate either
      # half: whichever call happened to land first would lock in
      # forever, even one caught mid-build missing every Paging-attached
      # word (limit/offset/cursor/nulls).
      #
      # @return [Array<Hash{Symbol => String}>] every declared Keyword row
      def keywords  = Bluebook::MetaValidator::SyntaxBoot.call[:keywords]

      # Every declared Argument row.
      #
      # @return [Array<Hash{Symbol => String}>] every declared Argument row
      def arguments = Bluebook::MetaValidator::SyntaxBoot.call[:arguments]

      # Reads a row's declared status, defaulting when it declared none.
      #
      # @param row [Hash{Symbol => String}] a Keyword or Argument row
      # @return [String] the row's declared status, defaulting to `"admitted"`
      #   when it declared none
      def status_of(row) = row[:status].to_s.empty? ? "admitted" : row[:status].to_s

      # Whether a row is still current enough to appear in the reference.
      #
      # @param row [Hash{Symbol => String}] a Keyword or Argument row
      # @return [Boolean] true if the row's status is `"admitted"` or `"deprecated"`
      def live?(row)     = %w[admitted deprecated].include?(status_of(row))

      # Every distinct context a keyword is declared in.
      #
      # @return [Array<String>] every distinct context a keyword is declared in
      def contexts = keywords.map { |row| row[:context] }.uniq

      # Derives a context's reference page filename.
      #
      # @param context [String, Symbol, #to_s] a context name, such as `"File"`
      # @return [String] the reference page's filename for that context
      def page_name(context) = "#{Naming.snake(context)}.md"

      # Every reference page, rendered fresh — prose carried over from
      # the committed pages, new words seeded with the sentinel, orphaned
      # prose refused.
      #
      # @param directory [String] path to the directory holding the committed
      #   reference pages, read for their hand-written prose
      # @return [Hash{String => String}] every page's filename (plus `"index.md"`)
      #   mapped to its freshly rendered Markdown content
      # @raise [RuntimeError] if a committed page carries prose for a word the
      #   language no longer declares in that context
      def pages(directory)
        contexts.each_with_object({}) do |context, pages|
          path = File.join(directory, page_name(context))
          prose = File.exist?(path) ? harvest(File.read(path)) : {}
          pages[page_name(context)] = render_page(context, prose, path)
        end.merge("index.md" => render_index)
      end

      # A word admitting two forms has two rows — syntax.bluebook's own
      # stated rule, and `identified_by` (a block, or a bare argument and
      # none) is the case that made it real again. One section per word all
      # the same: the prose is the word's rather than the form's, and the
      # argument rows join by (word, context) and so already cover every
      # form. Grouped rather than rendered per row, or a reader would meet
      # the same heading and the same paragraph twice.
      #
      # @param context [String] the context name, such as `"File"`
      # @param prose [Hash{String, Symbol => String}] hand-written prose harvested
      #   from the committed page, keyed by word (or `PREAMBLE` for the page's lede)
      # @param path [String] the page's file path, used only in the orphan-refusal
      #   message below
      # @return [String] the page's full rendered Markdown
      # @raise [RuntimeError] if `prose` carries a key for a word the language no
      #   longer declares in `context`
      def render_page(context, prose, path)
        words = keywords.select { |row| row[:context] == context }.group_by { |row| row[:word] }
        orphans = prose.keys - words.keys - [PREAMBLE]
        unless orphans.empty?
          raise "#{path} carries prose for #{orphans.join(', ')}, which the language no longer " \
                "declares in #{context} — deleting writing is a human's decision, so decide"
        end

        sections = words.map { |word, forms| render_word(forms, prose[word]) }
        preamble = prose[PREAMBLE].to_s.strip
        <<~PAGE
          # #{context}

          #{region_begin('page')}
          #{context_lede(context)}

          *The tables on this page are generated from the language's own
          aggregate-local syntax tables (`lib/hecks/language/**/*.bluebook`)
          by `bin/reference` — do not edit inside the markers. The prose
          between them is hand-written and survives regeneration.*
          #{GENERATED_END}
          #{"\n#{preamble}\n" unless preamble.empty?}
          #{sections.join("\n")}
        PAGE
      end

      # The one-line description of where a context's words are typed.
      #
      # @param context [String] the context name, such as `"File"` or `"Command"`
      # @return [String] a sentence naming where words in this context are typed
      def context_lede(context)
        openers = keywords.select { |row| row[:opens] == context }
        return "Words available at the top of a file." if context == "File"
        return "Words available in the type position of an `attribute`." if context == "Type"

        inside = openers.map { |row| "`#{row[:word]} do ... end`" }.uniq.join(" / ")
        inside.empty? ? "Words available in the #{context} body." : "Words available inside #{inside}."
      end

      # One spelling per form, everything else off the first row — the
      # columns that differ between two forms of one word are `body` (which
      # is what the spelling shows) and nothing else.
      #
      # @param forms [Array<Hash{Symbol => String}>] one word's Keyword rows, one
      #   per admitted form
      # @param prose [String, nil] the word's hand-written prose, or nil if none
      #   was harvested
      # @return [String] the word's rendered section, generated table plus prose
      def render_word(forms, prose)
        row = forms.first
        table = argument_table(row)
        facts = []
        facts << "opens a `#{row[:opens]}` body" unless row[:opens].to_s.empty?
        facts << "fills `#{row[:fills]}`" unless row[:fills].to_s.empty?
        facts << "**status: #{status_of(row)}**" unless status_of(row) == "admitted"
        facts << "was `#{row[:was]}`" unless row[:was].to_s.empty?
        spellings = forms.map { |form| "`#{signature(form)}`" }.join(" / ")

        <<~WORD
          ## #{row[:word]}

          #{generated_begin(row[:word])}
          #{spellings}#{" — #{facts.join(', ')}" unless facts.empty?}
          #{table}#{GENERATED_END}

          #{prose_or_sentinel(prose)}
        WORD
      end

      # Falls back to the TODO sentinel when a word has no prose yet.
      #
      # @param prose [String, nil] a word's hand-written prose, or nil if none
      #   was harvested
      # @return [String] `prose` stripped, or the TODO sentinel if it is blank
      def prose_or_sentinel(prose)
        text = prose.to_s.strip
        text.empty? ? TODO_SENTINEL : text
      end

      # Finds the Argument rows declared for one Keyword row's word.
      #
      # @param row [Hash{Symbol => String}] a Keyword row
      # @return [Array<Hash{Symbol => String}>] the Argument rows declared for
      #   this row's word, in this row's context
      def word_arguments(row)
        arguments.select { |arg| arg[:keyword] == row[:word] && arg[:context] == row[:context] }
      end

      # Builds the call spelling shown for one word.
      #
      # @param row [Hash{Symbol => String}] a Keyword row
      # @return [String] the word's call spelling, positional arguments then
      #   named ones, with a trailing `do ... end` unless its body is `"none"`
      def signature(row)
        positional = word_arguments(row).reject { |arg| arg[:at].to_s.empty? }
                                        .sort_by { |arg| arg[:at].to_i }
                                        .map { |arg| arg[:fills].to_s.empty? ? arg[:kind] : arg[:fills] }
        named = word_arguments(row).select { |arg| arg[:at].to_s.empty? }
                                   .map { |arg| "#{arg[:named]}:" }
        parts = positional + named
        base = parts.empty? ? row[:word] : "#{row[:word]} #{parts.join(', ')}"
        row[:body].to_s == "none" ? base : "#{base} do ... end"
      end

      # Renders one word's arguments as a Markdown table.
      #
      # @param row [Hash{Symbol => String}] a Keyword row
      # @return [String] a Markdown table of the row's arguments, or `""` if it
      #   declares none
      def argument_table(row)
        args = word_arguments(row)
        return "" if args.empty?

        lines = ["", "| argument | kind | required | fills |", "|---|---|---|---|"]
        args.each do |arg|
          name = arg[:at].to_s.empty? ? "`#{arg[:named]}:`" : "positional #{arg[:at]}"
          lines << "| #{name} | #{arg[:kind]} | #{arg[:required]} | #{arg[:fills]} |"
        end
        "#{lines.join("\n")}\n"
      end

      # Renders the reference index page.
      #
      # @return [String] the reference index page's rendered Markdown, one
      #   linked entry per context
      def render_index
        listed = contexts.map do |context|
          count = keywords.select { |row| row[:context] == context }.map { |row| row[:word] }.uniq.size
          "- [#{context}](#{page_name(context)}) — #{count} #{count == 1 ? 'word' : 'words'}"
        end
        <<~INDEX
          # The DSL reference

          One page per context — the place in a file where a word may be
          typed. Generated by `bin/reference` from the Syntax chapter;
          the prose between the generated markers is hand-written and
          survives regeneration.

          #{listed.join("\n")}
        INDEX
      end

      # Prose keyed by word: everything between a section's generated
      # region and the next `## ` heading (or end of file).
      #
      # Starts on `PREAMBLE` rather than nil so the text between the page's
      # own generated lede and its first word heading is carried over too
      # instead of being silently dropped. A page written before that
      # region existed has no generated marker ahead of its first `## `,
      # so nothing is collecting when that heading arrives and no empty
      # preamble is invented — the older shape reads back unchanged.
      # A single-pass line-scanning state machine (current/collecting/
      # buffer/in_fence) — each branch mutates shared local state that
      # carries into the next iteration, so splitting per branch would
      # mean passing all four back and forth by reference every line.
      #
      # @param text [String] a committed reference page's full Markdown source
      # @return [Hash{String, Symbol => String}] hand-written prose, keyed by
      #   word (or `PREAMBLE` for the page's lede); empty and TODO-sentinel-only
      #   entries are dropped
      # rubocop:disable-next Metrics/PerceivedComplexity
      def harvest(text)
        prose = {}
        current = PREAMBLE
        collecting = false
        buffer = []

        # A heading inside a fence is not a heading. `## something` is an
        # ordinary Ruby comment, and now that every word's section carries
        # runnable code, one written at the left margin would otherwise
        # end that section mid-example and orphan the rest of it under a
        # word the language never declared.
        in_fence = false

        text.each_line do |line|
          in_fence = !in_fence if line.start_with?("```")

          if !in_fence && (match = line.match(/\A## (\S+)\s*\z/))
            prose[current] = buffer.join.strip if current && collecting
            current = match[1]
            collecting = false
            buffer = []
          elsif line.include?(GENERATED_END)
            collecting = true
          elsif collecting
            buffer << line
          end
        end
        prose[current] = buffer.join.strip if current && collecting
        prose.reject { |_word, text_| text_.empty? || text_ == TODO_SENTINEL }
      end

      # Renders every reference page and writes each to `directory`.
      #
      # @param directory [String] path to the directory to write pages into,
      #   created if it does not exist
      # @return [void]
      # @raise [RuntimeError] if a committed page carries prose for a word the
      #   language no longer declares in that context
      def write!(directory)
        FileUtils.mkdir_p(directory)
        pages(directory).each do |name, content|
          File.write(File.join(directory, name), content)
        end
      end

      # README's own generated regions — the same marker convention as a
      # reference page, keyed by region id instead of a word, so the
      # index a reader lands on first can't drift from what actually
      # exists on disk either.
      #
      # @param root [String] the repository root
      # @return [Hash{String => String}] each region id mapped to its freshly
      #   rendered content
      def readme_regions(root)
        {
          "guides"    => guide_index(root),
          "reference" => reference_index(root),
          "tools"     => tool_table(root),
          "corpus"    => corpus_roster(root),
          "diagrams"  => diagram_showcase(root)
        }
      end

      # Lists every committed guide, linked and titled by its own heading.
      #
      # @param root [String] the repository root
      # @return [String] a Markdown list linking every committed guide, titled
      #   by its own `# ` heading
      def guide_index(root)
        paths = Dir.glob(File.join(root, "docs/implemented/guides/*.md"))
                   .reject { |p| %w[AUTHORING.md].include?(File.basename(p)) }
        lines = paths.map do |path|
          heading = File.foreach(path).find { |line| line.start_with?("# ") }
          title = heading ? heading.sub(/\A#\s*/, "").strip : File.basename(path)
          "- [#{title}](docs/implemented/guides/#{File.basename(path)})"
        end
        lines.join("\n")
      end

      # Links the reference index, with its context count.
      #
      # @param _root [String] unused; kept for the shape `readme_regions` calls
      #   every region renderer with
      # @return [String] one line linking the reference index, with its context count
      def reference_index(_root)
        count = contexts.size
        "[The DSL reference](docs/implemented/reference/index.md) — #{count} contexts, generated from " \
          "the aggregate-local tables under `lib/hecks/language/` and held to them by " \
          "`spec/reference_golden_spec.rb`."
      end

      # Lists every `bin/` script that opens with a comment, one row each.
      #
      # @param root [String] the repository root
      # @return [String] a Markdown table of every `bin/` script with an opening
      #   comment, one row each
      def tool_table(root)
        scripts = Dir.glob(File.join(root, "bin/*")).select { |p| File.file?(p) }.sort
        rows = scripts.filter_map { |path| [path, tool_summary(path)] }.select { |_, desc| desc }
        lines = ["| tool | |", "|---|---|"]
        rows.each { |path, desc| lines << "| `bin/#{File.basename(path)}` | #{desc} |" }
        lines.join("\n")
      end

      # The opening comment paragraph, not just the first line — a table
      # cell that trails off mid-clause reads worse than one that runs a
      # little long and says "...". A code-bearing comment (`field.name`,
      # `pattern:`) makes naive sentence-splitting on "." or ":" cut in
      # the wrong place, so this truncates on length alone.
      #
      # @param path [String] a `bin/` script's path
      # @return [String, nil] its opening comment paragraph, truncated to 140
      #   characters, or nil if the script opens with no comment
      def tool_summary(path)
        comment_lines = []
        started = false
        File.foreach(path).first(10).each do |line|
          if line.start_with?("#") && !line.start_with?("#!")
            next if !started && line.strip == "#"

            started = true
            comment_lines << line.sub(/\A#\s?/, "").rstrip
          elsif started
            break
          end
        end
        return nil if comment_lines.empty?

        text = comment_lines.join(" ").squeeze(" ")
        text.length > 140 ? "#{text[0, 137]}..." : text
      end

      # One real, committed file, read fresh — not re-derived from a boot
      # (this module never requires `hecks/projections/diagrams`, and
      # shouldn't just to draw one example). `docs/generated/diagrams/`
      # is already held to the declaration by `spec/diagrams_spec.rb`'s
      # own drift check; this just quotes its own output, so the two
      # can't independently drift from each other either — a stale
      # Order_lifecycle.mmd fails that spec long before this one runs.
      #
      # @param root [String] the repository root
      # @return [String] a Markdown section showcasing the generated diagram
      #   tooling, quoting `examples/pizzas`'s own committed Order lifecycle diagram
      def diagram_showcase(root)
        lifecycle = File.read(File.join(root, "docs/generated/diagrams/pizzas/Order_lifecycle.mmd")).strip
        <<~MARKDOWN.strip
          `bin/project_diagrams` reads a booted domain's own declaration and draws it as Mermaid — nine kinds so far: `<Name>_lifecycle.mmd`, `relationships.mmd`, `dispatch.mmd`, `roles.mmd`, `ports.mmd`, `read_models.mmd`, `<Name>_surface.mmd` (what a command does, and what it writes), `<Name>_saga.mmd`, and `frameworks.mmd`. Nothing hand-drawn — the same reason a domain is data at all. Order's own lifecycle, straight off the bluebook above:

          ```mermaid
          #{lifecycle}
          ```

          The full set for every domain in this checkout — `examples/pizzas`, `examples/banking` — lives in [`docs/generated/diagrams/`](docs/generated/diagrams/), held to the declaration by `spec/diagrams_spec.rb` the same drift-refusing way this page is held to its own source.
        MARKDOWN
      end

      # Lists every example domain, with its own declared vision.
      #
      # @param root [String] the repository root
      # @return [String] a Markdown list of every example domain with a
      #   `.bluebook` file, each with its own declared `vision` text
      def corpus_roster(root)
        dirs = Dir.glob(File.join(root, "examples/*/"))
        lines = dirs.filter_map do |dir|
          name = File.basename(dir.chomp("/"))
          bluebooks = Dir.glob(File.join(dir, "bluebook/*.bluebook"))
          bluebooks = Dir.glob(File.join(dir, "*.bluebook")) if bluebooks.empty?
          next if bluebooks.empty?

          vision = bluebooks.filter_map { |bluebook| File.read(bluebook)[/vision\s+"([^"]*)"/, 1] }.first
          "- **#{name}** — #{vision}"
        end
        lines.join("\n")
      end

      # Replaces every generated region inside `text` with its freshly rendered
      # content, leaving the hand-written parts of README untouched.
      #
      # @param root [String] the repository root
      # @param text [String] the README's current full text
      # @return [String] the README's text, with each generated region refreshed
      def render_readme(root, text)
        readme_regions(root).reduce(text) do |current, (id, content)|
          pattern = /#{Regexp.escape(region_begin(id))}.*?#{Regexp.escape(GENERATED_END)}/m
          current.sub(pattern) { "#{region_begin(id)}\n#{content}\n#{GENERATED_END}" }
        end
      end

      # Regenerates README's generated regions in place.
      #
      # @param root [String] the repository root
      # @return [void]
      def write_readme!(root)
        path = File.join(root, "README.md")
        File.write(path, render_readme(root, File.read(path)))
      end

      # An example a reader can see and the harness will actually run.
      # `ruby skip` is display-only by the doctest harness's own rule, and
      # a hidden `<!-- doctest:boot -->` block is setup rather than an
      # example — a word whose only "example" is invisible or inert is a
      # word still shipping on its prose alone, which is the thing this
      # gate exists to refuse.
      EXAMPLE_FENCE = /^```ruby(?: bluebook| boot)?[ \t]*$/

      # Whether a word's prose carries a runnable example.
      #
      # @param prose [String, nil] a word's hand-written prose, or nil
      # @return [Boolean] true if `prose` contains a runnable `ruby` or
      #   `ruby bluebook`/`ruby boot` fenced example
      def exemplified?(prose) = prose.to_s.match?(EXAMPLE_FENCE)

      # Every live word, paired with its prose. Both coverage gates ask a
      # question about this same walk and differ only in what they ask of
      # the prose, so they share it rather than each re-deriving the page
      # set — the two are meant to move together, and one drifting past
      # the other is how a word ends up counted documented by one and
      # missing to the other.
      #
      # `harvest` already rejects empty prose and the TODO sentinel, so a
      # word with nothing written for it arrives here with a nil.
      #
      # @param directory [String] path to the directory holding the committed
      #   reference pages
      # @return [Array(String, String, String), Array(String, String, nil)]
      #   `[word, context, prose]` for every live (admitted or deprecated) word,
      #   `prose` nil if none was harvested
      def live_words(directory)
        rows = contexts.flat_map do |context|
          path = File.join(directory, page_name(context))
          prose = File.exist?(path) ? harvest(File.read(path)) : {}
          keywords.select { |row| row[:context] == context && live?(row) }
                  .map { |row| [row[:word], context, prose[row[:word]]] }
        end
        rows.uniq { |word, context, _| [word, context] }
      end

      # Disambiguates a word by the context it is declared in.
      #
      # @param word [String] a word
      # @param context [String] the context it is declared in
      # @return [String] the word, disambiguated by its context
      def name_of(word, context) = "#{word} (#{context})"

      # The coverage gate's question: every live word with no prose yet.
      #
      # @param directory [String] path to the directory holding the committed
      #   reference pages
      # @return [Array<String>] each undocumented live word, named by `name_of`
      def undocumented(directory)
        live_words(directory).reject { |_word, _context, prose| prose }
                             .map { |word, context, _| name_of(word, context) }
      end

      # The second coverage gate: prose is a declaration, and a
      # declaration nothing runs cannot disagree with anything. A word
      # documented only in sentences can go stale — or describe a word
      # the runtime never wired at all, which this repository has already
      # shipped twice (`read_model`'s where/order_by/limit/offset, and
      # `role`/`goal` on a command). An example that runs is the only
      # documentation that can go red.
      #
      # @param directory [String] path to the directory holding the committed
      #   reference pages
      # @return [Array<String>] each live word with prose but no runnable
      #   example, named by `name_of`
      def unexemplified(directory)
        live_words(directory).reject { |_word, _context, prose| exemplified?(prose) }
                             .map { |word, context, _| name_of(word, context) }
      end
    end
  end
end
