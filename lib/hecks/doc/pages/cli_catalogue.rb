require_relative "../cli_guides"
require_relative "../prose_markers"

module Hecks
  module Doc
    module Pages
      # The command-line guides as live pages: each page's regions in reading order, a prose region
      # for each prose marker it carries and a projected region for each generated section, whose
      # source is `cli:<section>`.
      class CliCatalogue
        # A generated section's opening comment, or a prose marker.
        REGION_MARK = Regexp.union(CliGuides::BEGIN_MARK, ProseMarkers::MARKER)

        # The heading a generated section sits under: README's index, or a guide's commands.
        ANCHORS = { CliGuides::INDEX => "Modules" }.freeze

        # A page's first `# ` heading, capturing its words.
        TITLE = /^# (.+)$/

        # @param root [String] the checkout
        def initialize(root)
          @root = root
        end

        # @return [Array<Catalogue::Entry>] every CLI guide page
        def pages
          paths.map do |path|
            text = File.read(File.join(@root, path), encoding: "UTF-8")
            Catalogue::Entry.new(path, title(text, path), regions(path, text))
          end
        end

        # @param path [String] the page
        # @param text [String] its words
        # @return [Array<Catalogue::Region, ProseMarkers::Region>] its regions in reading order
        def regions(path, text)
          prose = ProseMarkers.read(path, text)
          text.scan(REGION_MARK).map do |section, _|
            section ? projected(section) : prose.shift
          end
        end

        private

        # @return [Array<String>] every CLI guide page, in path order
        def paths = CliGuides.pages(@root).keys.sort

        def projected(section)
          Catalogue::Region.new("AddProjected", ANCHORS.fetch(section, "Commands"), "cli:#{section}", "")
        end

        # @return [String] the page's first `# ` heading, or its file name
        def title(text, path) = text[TITLE, 1]&.strip || File.basename(path)
      end
    end
  end
end
