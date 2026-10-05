# frozen_string_literal: true

require "hecks"
require "hecks/vocabulary"
require_relative "../tools"

module Hecks
  module Tools
    # Writes the launcher forms of `docs/tools.md` from the `RetiredScript` rows of the Vocabulary
    # chapter. Each row names a command (or, in QualityControl, a query); its form is rendered from
    # that command's own arguments, the same projection the launcher parses against, so a form can
    # neither keep an argument the command dropped nor miss one it gained.
    #
    # Only the tables between the `generated:begin tools` and `generated:end tools` comments are
    # written; the prose around them is hand-written and left alone. With `--check` nothing is
    # written: the tool answers 1 and names the sections that differ from the rows.
    module ToolsDoc
      # The document, relative to the checkout.
      DOCUMENT = "docs/tools.md"

      # The sections of the document, in the order it lists them.
      SECTIONS = %w[Custodian Deploy Site Codebase QualityControl].freeze

      # The first line of a table, and the line that closes it.
      HEADER = "| launcher | replaces |\n|---|---|"

      module_function

      # @param argv [Array<String>] `--check` to compare without writing
      # @param root [String] the checkout
      # @return [Integer] 0, or 1 when `--check` finds a section out of date
      # @raise [SystemExit] when a section has no marked table
      def main(argv, root: Tools::ROOT)
        path = File.join(root, DOCUMENT)
        text = File.read(path, encoding: "UTF-8")
        fresh = projection(text, root)
        return report(text, fresh) if argv.include?("--check")

        File.write(path, fresh, encoding: "UTF-8") unless fresh == text
        puts(fresh == text ? "tools_doc: #{rows.size} rows, every table current" : "wrote #{DOCUMENT}")
        0
      end

      # @return [Array<Hash{String => String}>] the `RetiredScript` rows, in table order
      def rows = Hecks::Vocabulary.rows("RetiredScript")

      # The launcher form each retired script became, as the table lists it.
      #
      # @param root [String] the checkout
      # @return [Hash{String => String}] script name to its forms, joined with `; `; a command no
      #   script preceded (`(new)`) has none
      def forms(root: Tools::ROOT)
        @forms ||= {}
        @forms[root] ||= begin
          context = Context.new(root)
          rows.reject { |row| row["script"] == "(new)" }.group_by { |row| row["script"] }
              .transform_values { |group| group.map { |row| form(row, context) }.join("; ") }
        end
      end

      # @param text [String] the document as it stands
      # @param root [String] the checkout
      # @return [String] the document with each section's table rewritten from the rows
      # @raise [SystemExit] when a section has no marked table
      def projection(text, root)
        context = Context.new(root)
        SECTIONS.reduce(text) do |held, section|
          region = /(<!-- generated:begin tools section=#{section} -->\n).*?(<!-- generated:end tools -->)/m
          abort "tools_doc: #{DOCUMENT} has no marked table for #{section}" unless held.match?(region)

          held.sub(region) { "#{Regexp.last_match(1)}#{table(section, context)}\n#{Regexp.last_match(2)}" }
        end
      end

      # @param section [String] one of `SECTIONS`
      # @param context [Context] the booted chapters
      # @return [String] the section's table, header included
      def table(section, context)
        lines = rows.select { |row| row["section"] == section }.group_by { |row| row["script"] }.map do |script, group|
          cell = group.map { |row| cell(row, context) }.join("; ")
          "| #{cell} | #{script == '(new)' ? '(new: no `bin/` script)' : "`bin/#{script}`"} |"
        end
        [HEADER, *lines].join("\n")
      end

      # One form as the table shows it: in backticks, with a `|` escaped.
      def cell(row, context) = "`#{form(row, context).gsub('|', '\|')}`"

      # @param row [Hash{String => String}] a `RetiredScript` row
      # @param context [Context] the booted chapters
      # @return [String] the launcher form of the row's command or query
      def form(row, context)
        return row["form"] unless row["form"].to_s.empty?

        spec, words = context.spec_for(row)
        passes = row["passes"].to_s
        text = [*words, *argument_words(spec, skip: passes.empty? ? [] : %w[arguments])].join(" ")
        text += %( [arguments="#{passes}"]) unless passes.empty?
        text += " (#{row['note']})" unless row["note"].to_s.empty?
        "hecks #{text}"
      end

      # The words after the verb: the first argument bare, the rest `name=`, flags last.
      #
      # @param spec [Hash] a projected command or query
      # @param skip [Array<String>] arguments not to spell, because the row documents them itself
      # @return [Array<String>] each argument as the launcher spells it
      def argument_words(spec, skip: [])
        named = by_attribute(spec[:arguments].reject do |argument|
          argument[:minted] || skip.include?(argument[:path].split(".").first)
        end)
        # The launcher reads a bare word as the first argument, when that is not a flag.
        bare = named.first unless named.empty? || named.first[:type] == "Boolean"
        flags, plain = (named - [bare].compact).partition { |argument| argument[:type] == "Boolean" }
        [*(bracket(bare, "<#{bare[:path]}>") if bare),
         *plain.map { |argument| bracket(argument, "#{argument[:path]}=") },
         *flags.map { |argument| flag_word(argument) }]
      end

      # A one-field value object's `x.value` leaf is spelled as the attribute, `x`; a value object
      # with more fields keeps one leaf each.
      #
      # @param leaves [Array<Hash>] projected leaf arguments
      # @return [Array<Hash>] the arguments the launcher takes, one per attribute for a scalar
      def by_attribute(leaves)
        leaves.group_by { |argument| argument[:path].split(".").first }.flat_map do |head, group|
          group.size == 1 && group.first[:path].end_with?(".value") ? [group.first.merge(path: head)] : group
        end
      end

      # @param argument [Hash] a projected argument
      # @param word [String] how it is spelled
      # @return [String] `word`, in brackets when the argument is optional
      def bracket(argument, word) = argument[:required] ? word : "[#{word}]"

      # `--confirm` is what makes a verb act, so it stands bare; any other flag is optional.
      def flag_word(argument)
        word = "--#{argument[:path].tr('_', '-')}"
        argument[:path] == "confirm" ? word : "[#{word}]"
      end

      # @param text [String] the document as it stands
      # @param fresh [String] the document the rows give
      # @return [Integer] 0 when current, else 1 with the stale sections on stderr
      def report(text, fresh)
        return 0 if text == fresh

        stale = SECTIONS.reject { |section| section_text(text, section) == section_text(fresh, section) }
        warn "tools_doc: #{DOCUMENT} differs from the RetiredScript rows in: #{stale.join(', ')} " \
             "(run hecks regeneration_run.project_tools_doc --confirm)"
        1
      end

      # @return [String, nil] the marked table of one section
      def section_text(text, section)
        text[/<!-- generated:begin tools section=#{section} -->\n(.*?)<!-- generated:end tools -->/m, 1]
      end

      # The booted Hecks chapters the forms are rendered from, built once.
      class Context
        # @param root [String] the checkout
        def initialize(root)
          @runtime = Hecks.boot(File.join(root, "lib/hecks/hecks"), install_doors: false)
          @projections = {}
        end

        # @param row [Hash{String => String}] a `RetiredScript` row
        # @return [Array(Hash, Array<String>)] the projected command or query, and the words that
        #   name it on the command line
        # @raise [SystemExit] when the row names no command or query
        def spec_for(row)
          chapter = %w[Custodian Codebase].include?(row["section"]) ? "Hecks" : row["section"]
          cli = projection(chapter)
          name = "#{Naming.snake(row['aggregate'])}.#{row['verb']}"
          command = cli[:commands][cli[:names][:command][name]]
          question = cli[:questions][cli[:names][:question][name]]
          spec = command || question or abort "tools_doc: #{chapter} has no command or query #{name}"
          [spec, words(chapter, name, row)]
        end

        private

        def projection(chapter)
          @projections[chapter] ||= begin
            launcher = Doors::LauncherOptions.settings(@runtime, chapter)
            options = Doors::LauncherOptions.projection(launcher, "hecks")
            Projector.call(:cli, bluebook: @runtime.registry.bluebook(chapter), options: options)
          end
        end

        # `hecks ir`, `hecks console`, `hecks quality_control sweep.run`, `hecks host.check_era`.
        # The launcher takes a name that is only a query as a query, so no `query` word is needed.
        def words(chapter, name, row)
          settings = Doors::LauncherOptions.settings(@runtime, chapter) || {}
          route = (settings[:names] || {}).key(name)
          route ||= row["verb"] if chapter == "Hecks" && Array(settings[:legacy]).include?(row["verb"])
          return [route] if route

          [*(Naming.snake(chapter) unless chapter == "Hecks"), name]
        end
      end
    end
  end
end
