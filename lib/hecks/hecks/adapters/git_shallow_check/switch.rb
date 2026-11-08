# frozen_string_literal: true

module Hecks
  module Adapters
    class GitShallowCheck
      # The one switch of the shallow check: a marker file in the repository's git directory.
      #
      # The check is on when the marker is absent. Nothing is committed and no world is edited, so
      # `ShallowCheck.switch! state.value=off` silences every worktree of the repository at once.
      class Switch
        # The marker's name inside the common git directory.
        MARKER = "hecks-shallow-check-off"

        # @param git_dir [String] the repository's common git directory
        def initialize(git_dir)
          @path = File.join(git_dir, MARKER)
        end

        # @return [Boolean] whether the check runs
        def on? = !File.exist?(@path)

        # @param state [String] `on` or `off`
        # @return [String] the state now in force
        # @raise [ArgumentError] for any other word
        def set(state)
          raise ArgumentError, "state is on or off, not #{state.inspect}" unless %w[on off].include?(state)

          state == "off" ? File.write(@path, "off\n") : FileUtils.rm_f(@path)
          state
        end
      end
    end
  end
end
