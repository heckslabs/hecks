module Hecks
  module Doc
    module Reference
      # README's own generated regions, keyed by region id instead of a word. Extended onto
      # `Reference`.
      module Readme
        # README's own generated regions, keyed by region id instead of a word.
        def readme_regions(root)
          {
            "guides"    => guide_index(root),
            "reference" => reference_index(root),
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
          Dir.glob(File.join(root, "examples/*/")).filter_map { |dir| roster_line(dir) }.join("\n")
        end

        # @return [String, nil] the example's name and vision as a list item; nil without a bluebook
        def roster_line(dir)
          bluebooks = example_bluebooks(dir)
          return if bluebooks.empty?

          vision = bluebooks.filter_map { |bluebook| File.read(bluebook)[/vision\s+"([^"]*)"/, 1] }.first
          "- **#{File.basename(dir.chomp("/"))}** — #{vision}"
        end

        # @return [Array<String>] the example's bluebooks, under `bluebook/` or else beside it
        def example_bluebooks(dir)
          bluebooks = Dir.glob(File.join(dir, "bluebook/*.bluebook"))
          bluebooks.empty? ? Dir.glob(File.join(dir, "*.bluebook")) : bluebooks
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
      end
    end
  end
end
