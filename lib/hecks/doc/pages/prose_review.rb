require_relative "../prose_check"
require_relative "../prose_markers"

module Hecks
  module Doc
    module Pages
      # Puts up for review every declared prose region whose mentions or supports do not resolve,
      # through `Prose.FlagForReview` in the Memory boot of Docs, and reads them back with
      # `Prose.NeedsReview`.
      class ProseReview
        # @param runtime [Runtime::Dispatcher] the Memory boot of Docs, its pages declared
        # @param check [ProseCheck] answers what does not resolve
        def initialize(runtime, check)
          @runtime = runtime
          @check = check
        end

        # @param pages [Array<Catalogue::Entry>] the declared pages
        # @return [Array<String>] each prose region up for review, as `path#anchor: why`
        def drifts(pages)
          reasons = pages.flat_map { |page| unresolved(page) }.to_h
          reasons.each_key { |key| @runtime.dispatch_flat("Docs::Prose.FlagForReview", prose: key) }
          @runtime.query("Docs::Prose.NeedsReview").map do |row|
            key = row[:prose].value
            "#{key}: #{reasons.fetch(key, []).join("; ")}; revise the prose and its marker"
          end
        end

        private

        # @return [Array<Array(String, Array<String>)>] each of the page's prose regions that does
        #   not resolve, by key, with why
        def unresolved(page)
          prose = page.regions.grep(ProseMarkers::Region)
          prose.filter_map do |region|
            why = @check.unresolved(region)
            [region.key(page.path), why] unless why.empty?
          end
        end
      end
    end
  end
end
