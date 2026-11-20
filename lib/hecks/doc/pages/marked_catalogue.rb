require_relative "../regions"
require_relative "../prose_markers"
require "hecks/tools/tools_doc"

module Hecks
  module Doc
    module Pages
      # The top-level pages as live pages, each page's regions read from its own text in reading
      # order: a prose region for each prose marker, a projected region for each generated one.
      # A region marked `generated:begin id=<id>` is held to `region:<id>` (`Regions`), a section
      # table of the commands page to `tools:<Section>`.
      class MarkedCatalogue
        # The pages read this way: the commands page and every page `Regions` writes.
        PATHS = [Tools::ToolsDoc::DOCUMENT, *Regions::PAGES.keys].freeze

        # A generated region's opening comment, capturing its id or its tools section.
        GENERATED = /<!-- generated:begin (?:id=(\S+)|tools section=(\S+)) -->/

        # A generated region's opening comment, or a prose marker.
        REGION_MARK = Regexp.union(GENERATED, ProseMarkers::MARKER)

        # A page's first `# ` heading, capturing its words.
        TITLE = /^# (.+)$/

        # @param root [String] the checkout
        def initialize(root)
          @root = root
        end

        # @return [Array<Catalogue::Entry>] every top-level page
        def pages
          PATHS.map do |path|
            text = File.read(File.join(@root, path), encoding: "UTF-8")
            Catalogue::Entry.new(path, text[TITLE, 1]&.strip || File.basename(path), regions(path, text))
          end
        end

        # @param path [String] the page
        # @param text [String] its words
        # @return [Array<Catalogue::Region, ProseMarkers::Region>] its regions in reading order
        def regions(path, text)
          prose = ProseMarkers.read(path, text)
          text.scan(REGION_MARK).map do |id, section, _|
            next prose.shift unless id || section

            Catalogue::Region.new("AddProjected", id || section, id ? "region:#{id}" : "tools:#{section}", "")
          end
        end
      end
    end
  end
end
