# frozen_string_literal: true

module Hecks
  module Adapters
    module Codebase
      # The task families, each carrying out the operations it lists. `SourceTree` tries them in
      # order.
      module TaskFamilies
        ALL = [Language, KernelTables, Conformance, Regeneration, Gate, Style, Inspection, Codemods, TestSuite,
               CorpusTasks, Composing, Previewing, Publishing, Promotion, Scripting].freeze
      end
    end
  end
end
