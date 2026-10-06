require "fileutils"
require_relative "../bluebook/meta_validator"
require_relative "../naming"
require_relative "reference/harvester"
require_relative "reference/readme"
require_relative "reference/coverage"
require_relative "reference/rendering"

module Hecks
  module Doc
    # The DSL reference, projected from the language's own Syntax chapter so
    # its tables can never drift from the live builders. Regenerate with
    # `hecks language_run.project_reference`.
    #
    # README's regions are in `Readme` and the coverage gates in `Coverage`, both extended onto
    # this module; `Harvester` reads committed prose back.
    module Reference
      GENERATED_END = "<!-- generated:end -->".freeze
      TODO_SENTINEL = "<!-- TODO: document this word -->".freeze

      # A page's hand-written opening, keyed under a Symbol so it can never
      # collide with a word (words are always Strings off the Syntax chapter).
      PREAMBLE = :preamble

      extend Readme
      extend Coverage
      extend Rendering

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

      # Prose keyed by word: everything between a section's generated region
      # and the next `## ` heading.
      def harvest(text) = Harvester.new.call(text)

      # Renders every reference page and writes each to `directory`.
      def write!(directory)
        FileUtils.mkdir_p(directory)
        pages(directory).each do |name, content|
          File.write(File.join(directory, name), content)
        end
      end
    end
  end
end
