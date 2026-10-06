module Hecks
  module Doc
    module Reference
      # Renders the pages themselves: a context's page word by word, and the index. Extended onto
      # `Reference`.
      module Rendering
        # Renders one context's page, grouped by word (not per form) so a
        # two-form word doesn't repeat its heading and prose.
        def render_page(context, prose, path)
          words = keywords.select { |row| row[:context] == context }.group_by { |row| row[:word] }
          refuse_orphans!(prose, words, context, path)
          sections = words.map { |word, forms| render_word(forms, prose[word]) }
          page_markdown(context, prose[PREAMBLE].to_s.strip, sections)
        end

        # @raise [RuntimeError] when a page carries prose for a word the language does not declare
        def refuse_orphans!(prose, words, context, path)
          orphans = prose.keys - words.keys - [PREAMBLE]
          return if orphans.empty?

          raise "#{path} carries prose for #{orphans.join(", ")}, which the language no longer " \
                "declares in #{context} — deleting writing is a human's decision, so decide"
        end

        # @return [String] the page: its heading, generated lede, the hand-written preamble and the
        #   word sections
        def page_markdown(context, preamble, sections)
          <<~PAGE
            # #{context}

            #{region_begin("page")}
            #{context_lede(context)}

            *The tables on this page are generated from the language's own
            aggregate-local syntax tables (`lib/hecks/language/**/*.bluebook`)
            by `hecks language_run.project_reference` — do not edit inside the markers. The prose
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
          facts = word_facts(row)
          spellings = forms.map { |form| "`#{signature(form)}`" }.join(" / ")
          word_markdown(row, spellings, facts, argument_table(row), prose)
        end

        # @return [Array<String>] what a word's heading line states beyond its spelling
        def word_facts(row)
          [("opens a `#{row[:opens]}` body" unless row[:opens].to_s.empty?),
           ("fills `#{row[:fills]}`" unless row[:fills].to_s.empty?),
           ("**status: #{status_of(row)}**" unless status_of(row) == "admitted"),
           ("was `#{row[:was]}`" unless row[:was].to_s.empty?)].compact
        end

        # @return [String] one word's section: heading, generated region and prose
        def word_markdown(row, spellings, facts, table, prose)
          <<~WORD
            ## #{row[:word]}

            #{generated_begin(row[:word])}
            #{spellings}#{" — #{facts.join(", ")}" unless facts.empty?}
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
          args = word_arguments(row)
          parts = positional_parts(args) + named_parts(args)
          base = parts.empty? ? row[:word] : "#{row[:word]} #{parts.join(", ")}"
          row[:body].to_s == "none" ? base : "#{base} do ... end"
        end

        # @return [Array<String>] the positional arguments' kinds (or what they fill), in order
        def positional_parts(args)
          args.reject { |arg| arg[:at].to_s.empty? }
              .sort_by { |arg| arg[:at].to_i }
              .map { |arg| arg[:fills].to_s.empty? ? arg[:kind] : arg[:fills] }
        end

        # @return [Array<String>] the named arguments, as `name:`
        def named_parts(args)
          args.select { |arg| arg[:at].to_s.empty? }.map { |arg| "#{arg[:named]}:" }
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
            "- [#{context}](#{page_name(context)}) — #{count} #{count == 1 ? "word" : "words"}"
          end
          <<~INDEX
            # The DSL reference

            One page per context — the place in a file where a word may be
            typed. Generated by `hecks language_run.project_reference` from the Syntax chapter;
            the prose between the generated markers is hand-written and
            survives regeneration.

            #{listed.join("\n")}
          INDEX
        end
      end
    end
  end
end
