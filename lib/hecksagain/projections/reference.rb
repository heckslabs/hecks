require_relative "../doc/reference"
require_relative "../projector"

module Hecksagain
  module Projections
    # THE DSL REFERENCE PAGES, projected from the chapter's own Syntax
    # aggregate — the tables come from the declaration, the prose is
    # preserved from whatever is already committed.
    #
    # THE FIRST PROJECTION THAT EMITS A TREE. `emits: :files` says so,
    # and the framework writes the map rather than inferring one: a Hash
    # of path => contents and a Hash that merely holds strings are the
    # same object to Ruby, so only the projection can know which it
    # meant. This is the case the output contract was designed for and
    # deliberately left unimplemented until something real needed it.
    #
    # NOT PURE, and it cannot be. `Doc::Reference.pages` READS the
    # committed pages to harvest their prose, so the existing directory
    # is an input — passed as `from:` rather than assumed, so the
    # projection never reaches for a path of its own choosing.
    module Reference
      extend Projector::Target

      projects_as :reference, declares: "Syntax", emits: :files

      module_function

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
