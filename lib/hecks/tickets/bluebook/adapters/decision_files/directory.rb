# frozen_string_literal: true

require "hecks/runtime/errors"
require "hecks/adapters/driven/memory"

module Hecks
  module Adapters
    class DecisionFiles < Memory
      # Where the decision files are: the world's `directory` setting resolved against the
      # checkout that holds the booted domain.
      module Directory
        MARKER = "hecks.gemspec"
        NONE   = "None"

        module_function

        # @param setting [String, nil] the world's `directory`: absolute, relative to the checkout,
        #   or `None`
        # @param root [String, nil] the registry's root, inside the checkout
        # @return [String, nil] the directory; nil for `None` or no setting
        # @raise [Runtime::WiringError] if the named directory does not exist
        def resolve(setting, root)
          named = setting.to_s
          return nil if named.empty? || named.casecmp?(NONE)

          directory = File.absolute_path?(named) ? named : File.join(checkout(root) || File.expand_path(root.to_s), named)
          return directory if File.directory?(directory)

          raise Runtime::WiringError, "DecisionFiles: no directory #{directory} (the Tickets world names #{named.inspect})"
        end

        # The nearest directory at or above `root` holding `hecks.gemspec`.
        #
        # @param root [String, nil] a directory inside a checkout
        # @return [String, nil] the checkout; nil when no directory above `root` is one
        def checkout(root)
          current = File.expand_path(root.to_s)
          loop do
            return current if File.exist?(File.join(current, MARKER))

            parent = File.dirname(current)
            return nil if parent == current

            current = parent
          end
        end
      end
    end
  end
end
