require_relative "../bluebook/meta_validator"
require_relative "../naming"

module Hecks
  module Doc
    # The DSL reference, projected from the language's own Syntax chapter so
    # its tables can never drift from the live builders. Regenerate with `hecks project_reference`.
    module Reference
      GENERATED_END = "<!-- generated:end -->".freeze
      TODO_SENTINEL = "<!-- TODO: document this word -->".freeze

      # A page's hand-written opening, keyed under a Symbol so it can never
      # collide with a word (words are always Strings off the Syntax chapter).
      PREAMBLE = :preamble

      module_function

      # The marker opening one word's generated region.
      def generated_begin(word) = "<!-- generated:begin word=#{word} -->"

      # Same marker convention as generated_begin, keyed by region id for
      # parts of a page not about one word (a lede, README's indexes).
      def region_begin(id) = "<!-- generated:begin id=#{id} -->"

      # The language's own Syntax aggregate, read off the judged grammar chapter.
      def syntax
        meta = Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")
        meta.aggregates.find { |aggregate| aggregate.hecks_name == "Syntax" }
      end

      # Reads one closed-set value object's declared members off the Syntax
      # aggregate, as string-valued Hashes.
      def rows(name)
        syntax.value_objects.find { |vo| vo.hecks_name == name }
              .members.map { |row| row.to_h.transform_values(&:to_s) }
      end

      # Delegates to SyntaxBoot.call's own cache instead of memoizing here —
      # a second cache could lock in a stale set with no way to invalidate (ADR 0026).
      def keywords  = Bluebook::MetaValidator::SyntaxBoot.call[:keywords]

      # Every declared Argument row.
      def arguments = Bluebook::MetaValidator::SyntaxBoot.call[:arguments]

      # Reads a row's declared status, defaulting to "admitted" when it declared none.
      def status_of(row) = row[:status].to_s.empty? ? "admitted" : row[:status].to_s

      # Whether a row is still current enough to appear in the reference.
      def live?(row)     = %w[admitted deprecated].include?(status_of(row))

      # Every distinct context a keyword is declared in.
      def contexts = keywords.map { |row| row[:context] }.uniq

      # Derives a context's reference page filename.
      def page_name(context) = "#{Naming.snake(context)}.md"

      # Every reference page, rendered fresh: prose carried over from the
      # committed pages, new words seeded with the sentinel, orphaned prose refused.
      def pages(directory)
        contexts.each_with_object({}) do |context, pages|
          path = File.join(directory, page_name(context))
          prose = File.exist?(path) ? harvest(File.read(path)) : {}
          pages[page_name(context)] = render_page(context, prose, path)
        end.merge("index.md" => render_index)
      end

      # Renders one context's page, grouped by word (not per form) so a
      # two-form word doesn't repeat its heading and prose.
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
          by `hecks project_reference` — do not edit inside the markers. The prose
          between them is hand-written and survives regeneration.*
          #{GENERATED_END}
          #{"\n#{preamble}\n" unless preamble.empty?}
          #{sections.join("\n")}
        PAGE
      end

      # The one-line description of where a context's words are typed.
      def context_lede(context)
        openers = keywords.select { |row| row[:opens] == context }
        return "Words available at the top of a file." if context == "File"
        return "Words available in the type position of an `attribute`." if context == "Type"

        inside = openers.map { |row| "`#{row[:word]} do ... end`" }.uniq.join(" / ")
        inside.empty? ? "Words available in the #{context} body." : "Words available inside #{inside}."
      end

      # One section per word, built off forms.first — spelling is the only
      # column that differs between a word's two forms.
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
      def prose_or_sentinel(prose)
        text = prose.to_s.strip
        text.empty? ? TODO_SENTINEL : text
      end

      # The Argument rows declared for one Keyword row's word, in its context.
      def word_arguments(row)
        arguments.select { |arg| arg[:keyword] == row[:word] && arg[:context] == row[:context] }
      end

      # Builds the call spelling shown for one word: positional arguments
      # then named ones, with a trailing `do ... end` unless its body is "none".
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

      # Renders one word's arguments as a Markdown table, or "" if it declares none.
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

      # Renders the reference index page, one linked entry per context.
      def render_index
        listed = contexts.map do |context|
          count = keywords.select { |row| row[:context] == context }.map { |row| row[:word] }.uniq.size
          "- [#{context}](#{page_name(context)}) — #{count} #{count == 1 ? 'word' : 'words'}"
        end
        <<~INDEX
          # The DSL reference

          One page per context — the place in a file where a word may be
          typed. Generated by `hecks project_reference` from the Syntax chapter;
          the prose between the generated markers is hand-written and
          survives regeneration.

          #{listed.join("\n")}
        INDEX
      end

      # Prose keyed by word: everything between a section's generated region
      # and the next `## ` heading. Starts collecting under `PREAMBLE` (not nil)
      # so a page written before that region existed still parses unchanged.
      # rubocop:disable-next Metrics/PerceivedComplexity
      def harvest(text)
        prose = {}
        current = PREAMBLE
        collecting = false
        buffer = []

        # A `## ` line inside a fence is not a heading — it's a comment in
        # the runnable example, not a section break.
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
      def write!(directory)
        FileUtils.mkdir_p(directory)
        pages(directory).each do |name, content|
          File.write(File.join(directory, name), content)
        end
      end

      # README's own generated regions, keyed by region id instead of a word.
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
      def reference_index(_root)
        count = contexts.size
        "[The DSL reference](docs/implemented/reference/index.md) — #{count} contexts, generated from " \
          "the aggregate-local tables under `lib/hecks/language/` and held to them by " \
          "`spec/reference_golden_spec.rb`."
      end

      # Lists every `bin/` script that opens with a comment, one row each.
      def tool_table(root)
        scripts = Dir.glob(File.join(root, "bin/*")).select { |p| File.file?(p) }.sort
        rows = scripts.filter_map { |path| [path, tool_summary(path)] }.select { |_, desc| desc }
        lines = ["| tool | |", "|---|---|"]
        rows.each { |path, desc| lines << "| `bin/#{File.basename(path)}` | #{desc} |" }
        lines.join("\n")
      end

      # The opening comment paragraph, truncated to 140 chars rather than
      # split on sentence punctuation a code-bearing comment often contains.
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

      # Quotes the real, committed diagram file rather than re-deriving one,
      # so this can't drift from `spec/diagrams_spec.rb`'s own check.
      def diagram_showcase(root)
        lifecycle = File.read(File.join(root, "docs/generated/diagrams/pizzas/Order_lifecycle.mmd")).strip
        <<~MARKDOWN.strip
          `hecks project_diagrams` reads a booted domain's own declaration and draws it as Mermaid — nine kinds so far: `<Name>_lifecycle.mmd`, `relationships.mmd`, `dispatch.mmd`, `roles.mmd`, `ports.mmd`, `read_models.mmd`, `<Name>_surface.mmd` (what a command does, and what it writes), `<Name>_saga.mmd`, and `frameworks.mmd`. Nothing hand-drawn — the same reason a domain is data at all. Order's own lifecycle, straight off the bluebook above:

          ```mermaid
          #{lifecycle}
          ```

          The full set for every domain in this checkout — `examples/pizzas`, `examples/banking` — lives in [`docs/generated/diagrams/`](docs/generated/diagrams/), held to the declaration by `spec/diagrams_spec.rb` the same drift-refusing way this page is held to its own source.
        MARKDOWN
      end

      # Lists every example domain with a `.bluebook` file, with its own declared vision.
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
      def render_readme(root, text)
        readme_regions(root).reduce(text) do |current, (id, content)|
          pattern = /#{Regexp.escape(region_begin(id))}.*?#{Regexp.escape(GENERATED_END)}/m
          current.sub(pattern) { "#{region_begin(id)}\n#{content}\n#{GENERATED_END}" }
        end
      end

      # Regenerates README's generated regions in place.
      def write_readme!(root)
        path = File.join(root, "README.md")
        File.write(path, render_readme(root, File.read(path)))
      end

      # Matches a runnable `ruby`/`ruby bluebook`/`ruby boot` fenced example;
      # `ruby skip` and hidden boot blocks are setup, not an example, and don't count.
      EXAMPLE_FENCE = /^```ruby(?: bluebook| boot)?[ \t]*$/

      # Whether a word's prose carries a runnable example.
      def exemplified?(prose) = prose.to_s.match?(EXAMPLE_FENCE)

      # Every live word paired with its prose; shared by both coverage gates
      # so their page-walks can't drift apart.
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
      def name_of(word, context) = "#{word} (#{context})"

      # The coverage gate's question: every live word with no prose yet.
      def undocumented(directory)
        live_words(directory).reject { |_word, _context, prose| prose }
                             .map { |word, context, _| name_of(word, context) }
      end

      # The second coverage gate: prose alone can go stale or describe
      # unwired behavior; a runnable example is the only doc that can go red.
      def unexemplified(directory)
        live_words(directory).reject { |_word, _context, prose| exemplified?(prose) }
                             .map { |word, context, _| name_of(word, context) }
      end

      # Both coverage gates, worded for a person: each gap section lists the words that owe it,
      # and a word missing both kinds is listed twice, one repair each.
      #
      # @param directory [String] the reference pages
      # @return [Array(Boolean, String)] whether every live word is covered, and what to print
      def coverage_report(directory)
        gaps = [[undocumented(directory), "no prose — write their sections"],
                [unexemplified(directory), "no running example — write one in each word's own section"]]
        sections = gaps.reject { |words, _| words.empty? }.map do |words, owed|
          head = "#{words.size} live #{words.size == 1 ? 'word carries' : 'words carry'} #{owed}:\n"
          "#{head}#{words.map { |word| "  #{word}\n" }.join}\n"
        end
        return [true, "every live word carries prose and a running example."] if sections.empty?

        [false, sections.join]
      end
    end
  end
end
