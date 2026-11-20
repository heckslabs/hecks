require_relative "pages/catalogue"
require_relative "pages/prose_review"
require_relative "sources"

module Hecks
  module Doc
    # The documentation pages this checkout holds, declared through the Docs bluebook's own
    # commands into a Memory boot of it and read back with its `Page.Live` query, then each live
    # page's regions checked against their sources. The bluebook holds what a page is made of;
    # `Sources` answers whether a region still says what its source does.
    #
    # @example
    #   Hecks::Doc::Pages.drifts(root) # => [] when every live page matches its sources
    module Pages
      # The Docs domain's directory, booted standing alone in Memory.
      DOMAIN = File.expand_path("../docs", __dir__)

      module_function

      # @param root [String] the checkout
      # @return [Array<Hash>] every live page, as `{ path:, title:, regions: [{ anchor:, kind:,
      #   source:, assertion: }] }`, in path order
      def live(root)
        runtime = Hecks.boot(DOMAIN, environment: nil)
        Catalogue.new(root).pages.each { |page| declare(runtime, page) }
        runtime.query("Docs::Page.Live").map { |row| plain(row) }
      end

      # Every region that differs from its source. The CLI guides' prose regions are put up for
      # review, through `Prose.FlagForReview`, when a mention or support does not resolve; each
      # one up for review is a drift too.
      #
      # @param root [String] the checkout
      # @param doctest [#call, nil] runs one doctested page, answering true when its examples
      #   pass; nil leaves doctested regions to `spec/guides_spec.rb`
      # @return [Array<String>] each region that differs from its source, as `path#anchor: why`
      def drifts(root, doctest: nil)
        layout = CliGuides::Layout.new(root)
        sources = Sources.new(root, doctest: doctest, layout: layout)
        live(root).flat_map do |page|
          page[:regions].filter_map { |region| sources.drift(page[:path], region) }
        end + prose_drifts(root, layout)
      end

      # @param root [String] the checkout
      # @param layout [CliGuides::Layout] the launcher's reach
      # @return [Array<String>] each prose region up for review, as `path#anchor: why`
      def prose_drifts(root, layout)
        runtime = Hecks.boot(DOMAIN, environment: nil)
        pages = Catalogue.new(root).pages
        pages.each { |page| declare(runtime, page) }
        check = ProseCheck.new(root, layout, headed: MarkedCatalogue::PATHS)
        ProseReview.new(runtime, check).drifts(pages)
      end

      # Declares one catalogued page and adds its regions, in reading order.
      #
      # @param runtime [Runtime::Dispatcher] the Memory boot of Docs
      # @param page [Catalogue::Entry] the page
      # @return [void]
      def declare(runtime, page)
        runtime.dispatch_flat("Docs::Page.Declare", path: { value: page.path }, title: { value: page.title },
                                                    standing: { value: "live" })
        page.regions.each do |region|
          runtime.dispatch_flat(*region.command(page.path))
          follow_ups(region, page.path).each { |command| runtime.dispatch_flat(*command) }
        end
      end

      # @param region [Catalogue::Region, ProseMarkers::Region] one region
      # @param path [String] its page
      # @return [Array<Array(String, Hash)>] the Prose commands a prose region needs, else none
      def follow_ups(region, path)
        region.respond_to?(:follow_ups) ? region.follow_ups(path) : []
      end

      # @param row [Hash] one `Page.Live` row
      # @return [Hash] the row's path, title and regions as plain Strings
      def plain(row)
        { path: row[:path].value, title: row[:title].value,
          regions: row[:regions].map { |region| region_fields(region) } }
      end

      # @param region [Runtime::Value] one `Region`
      # @return [Hash{Symbol => String}] its anchor, kind, source and assertion
      def region_fields(region)
        %i[anchor kind source assertion].to_h { |field| [field, region.public_send(field).fetch(:value)] }
      end
    end
  end
end
