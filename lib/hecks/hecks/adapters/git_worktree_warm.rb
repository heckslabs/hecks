# frozen_string_literal: true

require "rbconfig"

module Hecks
  module Adapters
    # Starts the resident of a new worktree, so the first launcher lines run there are served and
    # not booted cold. A resident serves one checkout, and a worktree is a new one: without this its
    # first lines each pay a full boot until a cold line has started a resident for the next.
    #
    # The resident must run the worktree's own code, so it is started by a child Ruby that loads the
    # worktree's `lib`, never by this process, which may be another checkout's. The child is
    # detached and its answer is not waited for.
    #
    # Warming is an optimization, so it never fails the worktree: it starts nothing where residents
    # are switched off or the worktree has no launcher, and it swallows any error.
    module GitWorktreeWarm
      # What the child runs: the worktree's own `Starting`, given the worktree and its launcher.
      START = <<~RUBY.tr("\n", ";").freeze
        require "hecks/adapters/driving/resident/starting"
        Hecks::Adapters::Driving::Resident::Starting.call(ARGV[0], ARGV[1])
      RUBY

      module_function

      # @param path [String] the new worktree
      # @return [String, nil] `starting` once the child is launched, or nil when none is wanted
      #   here or it could not be launched
      def resident(path)
        script = File.join(path, "exe", "hecks")
        return unless wanted?(path, script)

        Process.detach(launch(path, script))
        "starting"
      rescue StandardError
        nil
      end

      # @return [Boolean] whether residents are on and the worktree holds a runnable launcher
      def wanted?(path, script)
        ENV.fetch("HECKS_NO_RESIDENT", "").empty? && File.executable?(script) &&
          File.directory?(File.join(path, "lib", "hecks"))
      end

      # @return [Integer] the pid of the child, which has no terminal and its own process group
      def launch(path, script)
        Process.spawn(RbConfig.ruby, "--disable-gems", "-I", File.join(path, "lib"), "-e", START, path, script,
                      in: File::NULL, out: File::NULL, err: File::NULL, pgroup: true)
      end
    end
  end
end
