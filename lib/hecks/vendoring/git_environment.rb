module Hecks
  module Vendoring
    # The environment a `git` subprocess needs to target one repository:
    # inherited GIT_DIR variables outrank `-C` and would redirect it elsewhere.
    module GitEnvironment
      # The variables that pin git to one repository, work tree or index.
      INHERITED = %w[
        GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR
        GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
      ].freeze

      # An environment hash for `Open3`, `IO.popen` and `system` that unsets
      # every repository-pinning variable and leaves the rest alone.
      #
      # @return [Hash{String => nil}] each inherited variable mapped to nil
      def self.clean
        INHERITED.to_h { |name| [name, nil] }
      end

      # Removes the repository-pinning variables from this process's own
      # environment, so every later `git` child starts clean.
      #
      # @return [void]
      def self.scrub!
        INHERITED.each { |name| ENV.delete(name) }
      end
    end
  end
end
