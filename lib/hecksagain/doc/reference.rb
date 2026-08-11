require_relative "../bluebook/meta_validator"
require_relative "../naming"

module Hecksagain
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

      module_function

      def generated_begin(word) = "<!-- generated:begin word=#{word} -->"

      def syntax
        meta = Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")
        meta.aggregates.find { |aggregate| aggregate.hecks_name == "Syntax" }
      end

      def rows(name)
        syntax.value_objects.find { |vo| vo.hecks_name == name }
              .members.map { |row| row.to_h.transform_values(&:to_s) }
      end

      def keywords  = @keywords  ||= rows("Keyword")
      def arguments = @arguments ||= rows("Argument")

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
        orphans = prose.keys - words.keys
        unless orphans.empty?
          raise "#{path} carries prose for #{orphans.join(', ')}, which the language no longer " \
                "declares in #{context} — deleting writing is a human's decision, so decide"
        end

        sections = words.map { |word, forms| render_word(forms, prose[word]) }
        <<~PAGE
          # #{context}

          #{context_lede(context)}

          *The tables on this page are generated from the language's own
          Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
          by `bin/reference` — do not edit inside the markers. The prose
          between them is hand-written and survives regeneration.*

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
      def harvest(text)
        prose = {}
        current = nil
        collecting = false
        buffer = []

        text.each_line do |line|
          if (match = line.match(/\A## (\S+)\s*\z/))
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
      README_REGION = ->(id) { "<!-- generated:begin id=#{id} -->" }

      def readme_regions(root)
        {
          "guides" => guide_index(root),
          "reference" => reference_index(root),
          "tools" => tool_table(root),
          "corpus" => corpus_roster(root)
        }
      end

      def guide_index(root)
        paths = Dir.glob(File.join(root, "docs/guides/*.md")).sort
                   .reject { |p| %w[AUTHORING.md].include?(File.basename(p)) }
        lines = paths.map do |path|
          heading = File.foreach(path).find { |line| line.start_with?("# ") }
          title = heading ? heading.sub(/\A#\s*/, "").strip : File.basename(path)
          "- [#{title}](docs/guides/#{File.basename(path)})"
        end
        lines.join("\n")
      end

      def reference_index(root)
        count = contexts.size
        "[The DSL reference](docs/reference/index.md) — #{count} contexts, generated from " \
          "`lib/hecksagain/language/bluebook/syntax.bluebook` and held to it by " \
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

      def corpus_roster(root)
        dirs = Dir.glob(File.join(root, "examples/*/")).sort
        lines = dirs.filter_map do |dir|
          name = File.basename(dir.chomp("/"))
          bluebook = Dir.glob(File.join(dir, "bluebook/*.bluebook")).first || Dir.glob(File.join(dir, "*.bluebook")).first
          next unless bluebook

          vision = File.read(bluebook)[/vision\s+"([^"]*)"/, 1]
          "- **#{name}** — #{vision}"
        end
        lines.join("\n")
      end

      def render_readme(root, text)
        readme_regions(root).reduce(text) do |current, (id, content)|
          pattern = /#{Regexp.escape(README_REGION.call(id))}.*?#{Regexp.escape(GENERATED_END)}/m
          current.sub(pattern) { "#{README_REGION.call(id)}\n#{content}\n#{GENERATED_END}" }
        end
      end

      def write_readme!(root)
        path = File.join(root, "README.md")
        File.write(path, render_readme(root, File.read(path)))
      end

      # The coverage gate's question: every LIVE word with no prose yet.
      def undocumented(directory)
        contexts.flat_map do |context|
          path = File.join(directory, page_name(context))
          prose = File.exist?(path) ? harvest(File.read(path)) : {}
          keywords.select { |row| row[:context] == context && live?(row) && prose[row[:word]].nil? }
                  .map { |row| "#{row[:word]} (#{context})" }.uniq
        end
      end
    end
  end
end
