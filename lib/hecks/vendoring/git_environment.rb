module Hecks
  module Vendoring
    # The environment a `git` subprocess needs so it resolves its repository
    # from the directory it is pointed at, not from whoever launched Ruby.
    #
    # Git exports `GIT_DIR`, `GIT_INDEX_FILE` and their kin to the hooks it
    # runs (a push from a linked worktree runs `pre-push` this way). Every
    # `git` that a hook's process tree starts inherits them, and they outrank
    # both `git -C` and the working directory: a command aimed at a scratch
    # repository would read, or commit into, the repository that was pushing.
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
