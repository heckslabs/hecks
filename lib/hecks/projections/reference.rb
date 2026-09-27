require_relative "../projector"

module Hecks
  # Repository-only tooling: `Doc::Reference` reads the committed pages under
  # `docs/`, which only a checkout has, so it loads on first use and the
  # packaged gem leaves it out (ADR 0066).
  module Doc
    autoload :Reference, File.expand_path("../doc/reference", __dir__)
  end

  module Projections
    # The DSL reference pages, projected from the chapter's Syntax aggregate;
    # tables come from the declaration, prose is preserved from what's already committed.
    module Reference
      extend Projector::Target

      projects_as :reference, declares: "Syntax", emits: :files

      module_function

      # Renders one reference page per DSL keyword context, carrying prose
      # over from whatever is already committed under `options[:from]`.
      #
      # @param bluebook [Bluebook::Behaviour::Chapter] the chapter declaring the
      #   Syntax aggregate to render pages from; unused beyond admission, since the
      #   keyword table this reads comes from the global `Syntax` grammar
      # @param options [Hash] must include `:from`
      # @option options [String] :from directory holding the already-committed
      #   reference pages, read to harvest their prose
      # @return [Hash{String => String}] each page's filename => its rendered
      #   Markdown, including `"index.md"`
      # @raise [ArgumentError] if `options[:from]` is missing or falsy
      def call(bluebook:, options: {})
        from = options[:from] or
          raise ArgumentError,
                ":reference harvests prose from the committed pages, so it needs " \
                "`from:` — the directory they live in"

        Doc::Reference.pages(from)
      end
    end
  end
end
