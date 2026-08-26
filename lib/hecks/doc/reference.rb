require_relative "../bluebook/meta_validator"
require_relative "../naming"

module Hecks
  module Doc
    # The DSL reference, projected from the language's own Syntax chapter
    # — the same Keyword/Argument rows the conformance specs hold equal
    # to the live builders. Nothing here is described twice: the tables
    # come from the declaration, the PROSE is hand-written between
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

      # A PAGE'S OWN HAND-WRITTEN OPENING, harvested under a key no word
      # can ever collide with (words are strings off the Syntax chapter;
      # this is a Symbol). It exists so a page can boot ONCE — load a real
      # corpus chapter, wire its hexagon — and have every word's example
      # below run against that single boot, the way a guide's opening
      # `ruby boot` block already does. Without it each word would have to
      # stand up its own domain, and 105 invented chapters would collide
      # on the facade constants `Surface.install` never uninstalls.
      PREAMBLE = :preamble

      module_function

      def generated_begin(word) = "<!-- generated:begin word=#{word} -->"

      # Keyed by REGION rather than by word — the same marker convention,
      # used for the parts of a page that are not about one word: a
      # page's generated lede here, README's generated indexes below.
      def region_begin(id) = "<!-- generated:begin id=#{id} -->"

      def syntax
        meta = Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")
        meta.aggregates.find { |aggregate| aggregate.hecks_name == "Syntax" }
      end

      def rows(name)
        syntax.value_objects.find { |vo| vo.hecks_name == name }
              .members.map { |row| row.to_h.transform_values(&:to_s) }
      end

      # S14, ADR 0026 — Keyword/Argument are genuine entities of Syntax
      # now, dispatched (not merely declared) so their own `status`
      # really is a lifecycle. `SyntaxBoot.call` discovers the static
      # aggregate-local seed rows (`KeywordSeed`/`ArgumentSeed`), dispatches each
      # one through the real admission/lifecycle door, and hands back the
      # same shape `rows` used to produce — nothing below this needed to
      # change.
      #
      # NO SEPARATE `@keywords ||=` HERE ANYMORE. This module used to
      # memoize its own copy on top of `SyntaxBoot.call`'s own memo — a
      # double cache with no way to invalidate either half, and a real
      # bug: whichever call in the whole process happened to land first
      # got locked in forever, even one caught mid-build missing every
      # Paging-attached word (limit/offset/cursor/nulls). `SyntaxBoot.call`
      # now carries the one cache that matters (keyed on the grammar
      # registry's own chapter set — see its comment) ; this delegates
      # straight through instead of shadowing it.
      def keywords  = Bluebook::MetaValidator::SyntaxBoot.call[:keywords]
      def arguments = Bluebook::MetaValidator::SyntaxBoot.call[:arguments]

      def status_of(row) = row[:status].to_s.empty? ? "admitted" : row[:status].to_s
      def live?(row)     = %w[admitted deprecated].include?(status_of(row))

      def contexts = keywords.map { |row| row[:context] }.uniq

      def page_name(context) = "#{Naming.snake(context)}.md"

      # Every reference page, rendered fresh — prose carried over from
      # the committed pages, new words seeded with the sentinel, orphaned
      # prose refused.
      def pages(directory)
        contexts.each_with_object({}) do |context, pages|
          path = File.join(directory, page_name(context))
          prose = File.exist?(path) ? harvest(File.read(path)) : {}
          pages[page_name(context)] = render_page(context, prose, path)
        end.merge("index.md" => render_index)
      end

      # A WORD ADMITTING TWO FORMS HAS TWO ROWS — syntax.bluebook's own
      # stated rule, and `identified_by` (a block, or a bare argument and
      # none) is the case that made it real again. One SECTION per word all
      # the same: the prose is the word's rather than the form's, and the
      # argument rows join by (word, context) and so already cover every
      # form. Grouped rather than rendered per row, or a reader would meet
      # the same heading and the same paragraph twice.
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
          #{preamble.empty? ? '' : "\n#{preamble}\n"}
          #{sections.join("\n")}
        PAGE
      end

      def context_lede(context)
        openers = keywords.select { |row| row[:opens] == context }
        return "Words available at the top of a file." if context == "File"
        return "Words available in the type position of an `attribute`." if context == "Type"

        inside = openers.map { |row| "`#{row[:word]} do ... end`" }.uniq.join(" / ")
        inside.empty? ? "Words available in the #{context} body." : "Words available inside #{inside}."
      end

      # One SPELLING per form, everything else off the first row — the
      # columns that differ between two forms of one word are `body` (which
      # is what the spelling shows) and nothing else.
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
          #{spellings}#{facts.empty? ? '' : " — #{facts.join(', ')}"}
          #{table}#{GENERATED_END}

          #{prose_or_sentinel(prose)}
        WORD
      end

      def prose_or_sentinel(prose)
        text = prose.to_s.strip
        text.empty? ? TODO_SENTINEL : text
      end

      def word_arguments(row)
        arguments.select { |arg| arg[:keyword] == row[:word] && arg[:context] == row[:context] }
      end

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

      def argument_table(row)
        args = word_arguments(row)
        return "" if args.empty?

        lines = ["", "| argument | kind | required | fills |", "|---|---|---|---|"]
        args.each do |arg|
          name = arg[:at].to_s.empty? ? "`#{arg[:named]}:`" : "positional #{arg[:at]}"
          lines << "| #{name} | #{arg[:kind]} | #{arg[:required]} | #{arg[:fills]} |"
        end
        lines.join("\n") + "\n"
      end

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
      # Starts on PREAMBLE rather than nil so the text between the PAGE's
      # own generated lede and its first word heading is carried over too
      # instead of being silently dropped. A page written before that
      # region existed has no generated marker ahead of its first `## `,
      # so nothing is collecting when that heading arrives and no empty
      # preamble is invented — the older shape reads back unchanged.
      def harvest(text)
        prose = {}
        current = PREAMBLE
        collecting = false
        buffer = []

        # A HEADING INSIDE A FENCE IS NOT A HEADING. `## something` is an
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
      def readme_regions(root)
        {
          "guides"    => guide_index(root),
          "reference" => reference_index(root),
          "tools"     => tool_table(root),
          "corpus"    => corpus_roster(root),
          "diagrams"  => diagram_showcase(root)
        }
      end

      def guide_index(root)
        paths = Dir.glob(File.join(root, "docs/implemented/guides/*.md")).sort
                   .reject { |p| %w[AUTHORING.md].include?(File.basename(p)) }
        lines = paths.map do |path|
          heading = File.foreach(path).find { |line| line.start_with?("# ") }
          title = heading ? heading.sub(/\A#\s*/, "").strip : File.basename(path)
          "- [#{title}](docs/implemented/guides/#{File.basename(path)})"
        end
        lines.join("\n")
      end

      def reference_index(root)
        count = contexts.size
        "[The DSL reference](docs/implemented/reference/index.md) — #{count} contexts, generated from " \
          "the aggregate-local tables under `lib/hecks/language/` and held to them by " \
          "`spec/reference_golden_spec.rb`."
      end

      def tool_table(root)
        scripts = Dir.glob(File.join(root, "bin/*")).select { |p| File.file?(p) }.sort
        rows = scripts.filter_map { |path| [path, tool_summary(path)] }.select { |_, desc| desc }
        lines = ["| tool | |", "|---|---|"]
        rows.each { |path, desc| lines << "| `bin/#{File.basename(path)}` | #{desc} |" }
        lines.join("\n")
      end

      # The opening comment PARAGRAPH, not just the first line — a table
      # cell that trails off mid-clause reads worse than one that runs a
      # little long and says "...". A code-bearing comment (`field.name`,
      # `pattern:`) makes naive sentence-splitting on "." or ":" cut in
      # the wrong place, so this truncates on LENGTH alone.
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

      # ONE REAL, COMMITTED FILE, READ FRESH — not re-derived from a boot
      # (this module never requires `hecks/projections/diagrams`, and
      # shouldn't just to draw one example). `docs/generated/diagrams/`
      # is already held to the declaration by `spec/diagrams_spec.rb`'s
      # own drift check; this just quotes its own output, so the two
      # can't independently drift from each other either — a stale
      # Order_lifecycle.mmd fails THAT spec long before this one runs.
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

      def corpus_roster(root)
        dirs = Dir.glob(File.join(root, "examples/*/")).sort
        lines = dirs.filter_map do |dir|
          name = File.basename(dir.chomp("/"))
          bluebooks = Dir.glob(File.join(dir, "bluebook/*.bluebook")).sort
          bluebooks = Dir.glob(File.join(dir, "*.bluebook")).sort if bluebooks.empty?
          next if bluebooks.empty?

          vision = bluebooks.filter_map { |bluebook| File.read(bluebook)[/vision\s+"([^"]*)"/, 1] }.first
          "- **#{name}** — #{vision}"
        end
        lines.join("\n")
      end

      def render_readme(root, text)
        readme_regions(root).reduce(text) do |current, (id, content)|
          pattern = /#{Regexp.escape(region_begin(id))}.*?#{Regexp.escape(GENERATED_END)}/m
          current.sub(pattern) { "#{region_begin(id)}\n#{content}\n#{GENERATED_END}" }
        end
      end

      def write_readme!(root)
        path = File.join(root, "README.md")
        File.write(path, render_readme(root, File.read(path)))
      end

      # An example A READER CAN SEE and the harness will actually run.
      # `ruby skip` is display-only by the doctest harness's own rule, and
      # a hidden `<!-- doctest:boot -->` block is setup rather than an
      # example — a word whose only "example" is invisible or inert is a
      # word still shipping on its prose alone, which is the thing this
      # gate exists to refuse.
      EXAMPLE_FENCE = /^```ruby(?: bluebook| boot)?[ \t]*$/.freeze

      def exemplified?(prose) = prose.to_s.match?(EXAMPLE_FENCE)

      # EVERY LIVE WORD, PAIRED WITH ITS PROSE. Both coverage gates ask a
      # question about this same walk and differ only in what they ask of
      # the prose, so they share it rather than each re-deriving the page
      # set — the two are meant to move together, and one drifting past
      # the other is how a word ends up counted documented by one and
      # missing to the other.
      #
      # `harvest` already rejects empty prose and the TODO sentinel, so a
      # word with nothing written for it arrives here with a nil.
      def live_words(directory)
        contexts.flat_map { |context|
          path = File.join(directory, page_name(context))
          prose = File.exist?(path) ? harvest(File.read(path)) : {}
          keywords.select { |row| row[:context] == context && live?(row) }
                  .map { |row| [row[:word], context, prose[row[:word]]] }
        }.uniq { |word, context, _| [word, context] }
      end

      def name_of(word, context) = "#{word} (#{context})"

      # The coverage gate's question: every LIVE word with no prose yet.
      def undocumented(directory)
        live_words(directory).reject { |_word, _context, prose| prose }
                             .map { |word, context, _| name_of(word, context) }
      end

      # The SECOND coverage gate: prose is a declaration, and a
      # declaration nothing runs cannot disagree with anything. A word
      # documented only in sentences can go stale — or describe a word
      # the runtime never wired at all, which this repository has already
      # shipped twice (`read_model`'s where/order_by/limit/offset, and
      # `role`/`goal` on a command). An example that RUNS is the only
      # documentation that can go red.
      def unexemplified(directory)
        live_words(directory).reject { |_word, _context, prose| exemplified?(prose) }
                             .map { |word, context, _| name_of(word, context) }
      end
    end
  end
end
