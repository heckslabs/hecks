require_relative "../runtime/storage_shape"
require_relative "../projector"

module Hecks
  module Projections
    # THE STORAGE SHAPE of one bluebook — the same structural form
    # `StorageShape.mint_hash` hashes to name an era, which is what makes
    # a bump/no-bump question answerable by diffing two of these.
    #
    # THE RETROFIT, and the point of it: `Runtime::StorageShape.project`
    # was written long before this framework existed, and it already
    # takes exactly one bluebook, already returns a plain Hash, already
    # touches no disk and no live runtime — it even already uses the
    # word. Nothing about it was shaped to fit `call(bluebook:, options:)`.
    #
    # That it fits anyway, by a two-line keyword adapter and no change to
    # `StorageShape` itself, is the evidence that the protocol is a real
    # description of what projections do here rather than a shape fitted
    # around its own first example (`:ir`, whose `call` is `to_h`, proves
    # much less on its own).
    module Shape
      extend Projector::Target

      projects_as :shape

      module_function

      def call(bluebook:, options: {}) = Runtime::StorageShape.project(bluebook)
    end
  end
end
