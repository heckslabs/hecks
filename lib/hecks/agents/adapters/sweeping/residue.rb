# frozen_string_literal: true

module Hecks
  module Adapters
    class Sweeping
      # What a removed session left in the temp directory: the files named for it. A worktree it
      # left is read with every other one by {Worktrees}.
      class Residue
        # @param tmp [String] the temp directory searched for files named for a session
        def initialize(tmp:)
          @tmp = tmp
        end

        # @param session [String] a removed session's short id
        # @return [Array<String>] the temp files named for it
        def temp_files(session)
          Dir.glob(File.join(@tmp, "*#{session}*")).select { |path| File.file?(path) && !File.symlink?(path) }
        end
      end
    end
  end
end
