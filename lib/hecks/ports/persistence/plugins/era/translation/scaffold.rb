require_relative "scaffold/differ"
require_relative "scaffold/renderer"
require_relative "scaffold/writer"

module Hecks
  module Translation
    # Diffs the held era's storage shape against the current one and writes the edge file.
    # Ambiguities become parse-refusing `unresolved` constructs; it never proposes compute or drop.
    module Scaffold
      Edge = Struct.new(:domain, :from, :to, :ordinal, :label, :aggregates, :retired, keyword_init: true)
      ScaffoldedAggregate = Struct.new(:name, :was, :rules, keyword_init: true)

      extend Differ
      extend Renderer
      extend Writer
    end
  end
end
