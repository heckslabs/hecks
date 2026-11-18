# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # The top-level package directories of this repository, which a work item's area should not
      # name: one holds so much that it keeps every other work item in it from starting. The area
      # should name the files the work item edits, or a directory well below a root.
      module PackageRoots
        # The directories that are a whole package or more.
        LIST = %w[lib lib/hecks lib/hecks/hecks spec rust rust/src docs exe packages].freeze

        module_function

        # @param item [#key, #area] a work item
        # @return [String, nil] the line that names the roots the work item claims and the list,
        #   nil when it claims none
        def warning(item)
          named = item.area.select { |word| LIST.include?(word.to_s.strip.chomp("/")) }
          return if named.empty?

          "warning: #{item.key} claims #{named.join(", ")}, a top-level package directory; " \
            "name the files it edits (package directories: #{LIST.join(", ")})"
        end
      end
    end
  end
end
