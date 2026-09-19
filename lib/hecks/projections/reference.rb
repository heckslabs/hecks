require_relative "../doc/reference"
require_relative "../projector"

module Hecks
  module Projections
    # The DSL reference pages, projected from the chapter's own Syntax
    # aggregate — the tables come from the declaration, the prose is
    # preserved from whatever is already committed.
    #
    # The first projection that emits a tree. `emits: :files` says so,
    # and the framework writes the map rather than inferring one: a Hash
    # of path => contents and a Hash that merely holds strings are the
    # same object to Ruby, so only the projection can know which it
    # meant. This is the case the output contract was designed for and
    # deliberately left unimplemented until something real needed it.
    #
    # Not pure, and it cannot be. `Doc::Reference.pages` reads the
    # committed pages to harvest their prose, so the existing directory
    # is an input — passed as `from:` rather than assumed, so the
    # projection never reaches for a path of its own choosing.
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
