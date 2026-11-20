require_relative "cli_guides/layout"
require_relative "cli_guides/rendering"

module Hecks
  module Doc
    # The generated sections of the command-line guides (`docs/implemented/guides/cli/`): each
    # module guide's commands and queries, and README's index of the guides, projected from the
    # module layout of ADR 0163. Only the text between a `generated:begin cli section=<name>` and
    # a `generated:end cli` comment is written; the prose around it is a person's.
    #
    # @example
    #   Hecks::Doc::CliGuides.main(true, root: root) # => 0 when every section is current
    module CliGuides
      # The guides' directory, relative to the checkout.
      DIRECTORY = "docs/implemented/guides/cli".freeze

      # The section README's index of the guides is written into.
      INDEX = "index".freeze

      # The comment that opens a generated section, capturing the section's name.
      BEGIN_MARK = /<!-- generated:begin cli section=(\S+) -->/

      # The comment that closes a generated section.
      END_MARK = "<!-- generated:end cli -->".freeze

      module_function

      # Writes every guide's generated sections, or with `check` compares them.
      #
      # @param check [Boolean] whether to compare without writing
      # @param root [String] the checkout
      # @return [Integer] 0, or 1 when `check` finds a section out of date
      def main(check, root:)
        layout = Layout.new(root)
        stale = pages(root).keys.reject { |path| current?(layout, root, path, write: !check) }
        return 0 if stale.empty?

        warn "cli guides: differ from the module layout in: #{stale.join(", ")} " \
             "(run hecks regeneration_run.project_tools_doc! --confirm)"
        1
      end

      # @param root [String] the checkout
      # @return [Hash{String => Array<String>}] each guide page's path to the sections it marks, in
      #   reading order: `index` in README, a module's word in its guide
      def pages(root)
        Dir.glob(File.join(root, DIRECTORY, "*.md")).to_h do |file|
          [file.delete_prefix("#{root}/"), sections(File.read(file, encoding: "UTF-8"))]
        end
      end

      # @param text [String] a page
      # @return [Array<String>] the sections it marks, in reading order
      def sections(text) = text.scan(BEGIN_MARK).flatten

      # @param layout [Layout] the command line's modules
      # @param root [String] the checkout
      # @param section [String] `index` or a module word
      # @return [String] the section's body as the layout gives it
      # @raise [ArgumentError] when the word names no module
      def render(layout, root, section)
        return Rendering.index(layout, guide_words(root)) if section == INDEX

        name = layout.modules.map(&:first).find { |candidate| Naming.snake(candidate) == section }
        raise ArgumentError, "cli guides: no module named #{section}" unless name

        Rendering.module_section(layout, name)
      end

      # @param text [String] a page as it stands
      # @param section [String] the section it holds
      # @return [String, nil] the section as the page holds it, markers included
      def section_text(text, section) = text[marker(section)]

      # @param text [String] a page as it stands
      # @param section [String] a section it marks
      # @param body [String] the section's fresh body
      # @return [String] the page with that section rewritten
      def rewrite(text, section, body)
        text.sub(marker(section)) { "#{begin_mark(section)}\n#{body}#{END_MARK}" }
      end

      # @return [String] the comment that opens a generated section
      def begin_mark(section) = "<!-- generated:begin cli section=#{section} -->"

      # @return [Regexp] a marked section, markers included
      def marker(section) = /#{Regexp.escape(begin_mark(section))}\n.*?#{Regexp.escape(END_MARK)}/m

      # @return [Array<String>] the words of the guide pages that hold a module's section
      def guide_words(root)
        pages(root).values.flatten - [INDEX]
      end

      # @param text [String] a page as it stands
      # @return [String] the page with every section it marks rewritten from the layout
      def projection(layout, root, text)
        sections(text).reduce(text) { |held, section| rewrite(held, section, render(layout, root, section)) }
      end

      # @return [Boolean] whether the page is current; writes it when `write` and it is not
      def current?(layout, root, path, write:)
        file = File.join(root, path)
        text = File.read(file, encoding: "UTF-8")
        fresh = projection(layout, root, text)
        File.write(file, fresh, encoding: "UTF-8") if write && fresh != text
        write || fresh == text
      end
    end
  end
end
