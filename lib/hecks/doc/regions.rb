require_relative "reference"
require_relative "regions/bluebook_map"
require_relative "regions/route_vocabulary"
require_relative "regions/decision_index"

module Hecks
  module Doc
    # The marked regions of pages other than README that are projected from the model, by page
    # and region id. A region sits between `<!-- generated:begin id=<id> -->` and
    # `<!-- generated:end -->`, README's own marker grammar; the words around it are the page's.
    # `language_run.project_reference!` writes them, and `Sources` holds each to its renderer
    # under the source `region:<id>`.
    #
    # @example
    #   Hecks::Doc::Regions.render(root, "docs/site-routes.md", text) # => text, regions refreshed
    module Regions
      # Each page's projected regions, by id, to the renderer that writes it.
      PAGES = {
        "docs/architecture-map.md" => { "bluebooks" => BluebookMap },
        "docs/site-routes.md"      => { "route-vocabulary" => RouteVocabulary },
        "docs/decisions/README.md" => { "decisions" => DecisionIndex }
      }.freeze

      module_function

      # @param root [String] the checkout
      # @param path [String] a page in `PAGES`, relative to the checkout
      # @param text [String] the page as it stands
      # @return [String] the page with each of its regions freshly rendered; a region with no
      #   markers in `text` is left out, and `Sources` names it
      def render(root, path, text)
        PAGES.fetch(path).reduce(text) do |current, (id, renderer)|
          current.sub(marked(id)) { "#{Reference.region_begin(id)}\n#{renderer.render(root)}\n#{Reference::GENERATED_END}" }
        end
      end

      # @param root [String] the checkout
      # @return [Hash{String => String}] README and each page of `PAGES`, by absolute path, with
      #   its marked regions freshly rendered
      def files(root)
        readme = File.join(root, "README.md")
        pages = PAGES.keys.to_h do |path|
          file = File.join(root, path)
          [file, render(root, path, File.read(file, encoding: "UTF-8"))]
        end
        pages.merge(readme => Reference.render_readme(root, File.read(readme)))
      end

      # @param id [String] a region id
      # @return [Regexp] the region's markers and everything between them
      def marked(id) = /#{Regexp.escape(Reference.region_begin(id))}.*?#{Regexp.escape(Reference::GENERATED_END)}/m
    end
  end
end
