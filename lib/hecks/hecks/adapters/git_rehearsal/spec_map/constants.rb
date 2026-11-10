# frozen_string_literal: true

module Hecks
  module Adapters
    class GitRehearsal
      class SpecMap
        # The constants a Ruby file defines, read from its `module` and `class` lines by indent.
        #
        # Only a leaf declaration counts, one with no declaration nested in it, named by its whole
        # nesting (`Hecks::ShapeLedger::EdgeHygiene`). The namespaces a leaf sits in are left
        # out, so a spec that only mentions `Hecks::ShapeLedger` is not tied to every file under it.
        class Constants
          DECLARATION = /^([ \t]*)(?:class|module)\s+([A-Z][\w:]*)/

          # @param text [String] the Ruby source
          def initialize(text)
            @text = text
          end

          # @return [Array<String>] the qualified name of each leaf declaration, in file order
          def leaves
            declared = qualified
            declared.each_with_index.filter_map do |(indent, name), at|
              name if (declared[at + 1]&.first || 0) <= indent
            end.uniq
          end

          private

          # Each declaration as its indent and its name under the declarations that enclose it.
          def qualified
            open = []
            @text.scan(DECLARATION).map do |indent, name|
              open.pop while open.any? && open.last.first >= indent.size
              open << [indent.size, [open.last&.last, name].compact.join("::")]
              open.last
            end
          end
        end
      end
    end
  end
end
