require_relative "scaffold/differ"
require_relative "scaffold/renderer"
require_relative "scaffold/writer"

module Hecks
  module Translation
    # The scaffold writes translations; humans resolve ambiguity. It
    # diffs the held era's storage-shape projection against the current
    # one (scaffold/differ.rb) and WRITES the edge file
    # (scaffold/renderer.rb, scaffold/writer.rb): confident rules inline
    # (unique signature pairs → rename/move, aggregate renames → `was:`,
    # type renames with identical members → retype, aggregates gone
    # without a successor → retired), ambiguities as parse-refusing
    # `unresolved` constructs — never comments, so an unresolved file can
    # only boot into a refusal, never a guess. It NEVER proposes a
    # `compute` (a computation takes domain judgment no mechanical diff
    # can infer) — an empty-candidate `unresolved` is what points the
    # author there. It never proposes a `drop` either: data loss is a
    # decision, not a default. Re-running regenerates the file, matched
    # by shape pair.
    module Scaffold
      Edge = Struct.new(:domain, :from, :to, :ordinal, :label, :aggregates, :retired, keyword_init: true)
      ScaffoldedAggregate = Struct.new(:name, :was, :rules, keyword_init: true)

      extend Differ
      extend Renderer
      extend Writer
    end
  end
end
