require_relative "../reference"
require "hecks/tools/tools_doc"
require_relative "cli_catalogue"
require_relative "marked_catalogue"

module Hecks
  module Doc
    module Pages
      # The live pages of a checkout and the regions each is made of: README's generated regions
      # and its examples, the marked regions and prose of the top-level pages (`MarkedCatalogue`),
      # every DSL reference page, every guide's examples, and the command-line guides' generated
      # sections and prose. Each region
      # names its source as `<source>:<target>` (see `Sources`).
      class Catalogue
        # One page to declare: its path, title and regions in reading order.
        Entry = Data.define(:path, :title, :regions)

        # One region to add: the Docs command that adds it and that command's fields.
        Region = Data.define(:verb, :anchor, :source, :assertion) do
          # @param path [String] the page the region belongs to
          # @return [Array(String, Hash)] the command and its flat arguments
          def command(path)
            fields = { page: path, anchor: { value: anchor }, source: { value: source } }
            fields[:assertion] = { value: assertion } if verb == "AddDoctested"
            ["Docs::Page.#{verb}", fields]
          end
        end

        # What a doctested page's examples are asserted to show once booted.
        DOCTEST_ASSERTION = "says nothing its examples cannot back".freeze

        # The DSL reference index, which carries no word and so no example.
        REFERENCE_INDEX = "docs/implemented/reference/index.md".freeze

        # Guides with no claims of their own to back.
        UNGUIDED = %w[AUTHORING.md index.md].freeze

        # @param root [String] the checkout
        def initialize(root)
          @root = root
        end

        # @return [Array<Entry>] every live page
        def pages
          [readme] + MarkedCatalogue.new(@root).pages + reference + guides + CliCatalogue.new(@root).pages
        end

        # @return [Entry] README: its generated regions, then its examples
        def readme
          regions = Reference.readme_regions(@root).keys.map { |id| projected(id, "readme:#{id}") }
          Entry.new("README.md", title_of("README.md"), regions + [doctested("README.md")])
        end

        # @return [Array<Entry>] every DSL reference page, projected whole from the Syntax bluebook;
        #   each word page also has its examples booted
        def reference
          (reference_paths + [REFERENCE_INDEX]).map do |path|
            name = File.basename(path)
            examples = path == REFERENCE_INDEX ? [] : [doctested(path)]
            Entry.new(path, title_of(path), [projected(name, "reference:#{name}")] + examples)
          end
        end

        # @return [Array<String>] every DSL reference word page, one per declared context
        def reference_paths
          Reference.contexts.map { |context| "docs/implemented/reference/#{Reference.page_name(context)}" }
        end

        # @return [Array<Entry>] every guide, one doctested region each
        def guides = guide_paths.map { |path| Entry.new(path, title_of(path), [doctested(path)]) }

        # @return [Array<String>] every guide page whose examples are booted, README last
        def guide_doctest_paths = guide_paths + ["README.md"]

        # @return [Array<String>] every guide with claims to back, relative to the checkout
        def guide_paths
          Dir.glob(File.join(@root, "docs/implemented/guides/*.md"))
             .reject { |file| UNGUIDED.include?(File.basename(file)) }
             .map { |file| relative(file) }
        end

        private

        def projected(anchor, source) = Region.new("AddProjected", anchor, source, "")

        def doctested(path) = Region.new("AddDoctested", "Examples", "doctest:#{path}", DOCTEST_ASSERTION)

        def relative(file) = file.delete_prefix("#{@root}/")

        # @return [String] the page's first `# ` heading, or its file name when it has none
        def title_of(path)
          file = File.join(@root, path)
          heading = File.exist?(file) && File.foreach(file).find { |line| line.start_with?("# ") }
          heading ? heading.sub(Reference::Readme::HEADING_MARK, "").strip : File.basename(path)
        end
      end
    end
  end
end
