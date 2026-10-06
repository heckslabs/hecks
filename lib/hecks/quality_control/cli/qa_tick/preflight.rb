# frozen_string_literal: true

require "open3"

module Hecks
  module QualityControlCli
    class QaTick
      # What a tick does before any step runs: the process set-up, the libraries every step shares,
      # and the clean-tree check and rebase that start a tick from `origin/main`.
      module Preflight
        # The libraries the steps need, loaded once by the tick rather than once per step.
        STEP_LIBRARIES = [
          "hecks", "hecks/ports/persistence/plugins/era", "hecks/fuzzing", "hecks/fuzzing/self_consistency",
          "hecks/fuzzing/differential", "hecks/fuzzing/era_boundary", "hecks/fuzzing/concurrent_dispatch",
          "hecks/fuzzing/domain_generator", "hecks/fuzzing/generated_domain_check",
          "hecks/quality_control/adapters/git_pr", "hecks/quality_control/cli/qa_pr_check",
          "hecks/quality_control/cli/qa_sweep", "hecks/quality_control/cli/qa_generated_domains"
        ].freeze

        private

        # **macOS only, harmless elsewhere.** `fork` below can race Apple's Objective-C runtime
        # initializing a class in a background thread and crash the forked child outright ("may
        # have been in progress in another thread when fork() was called... Crashing instead").
        # Spring's preload-and-fork test runner sets this same flag for the same reason. It has to
        # be in the environment before the Ruby interpreter itself starts, since setting it via
        # `ENV[]` from inside an already-running process is too late (libobjc has already decided by
        # then), so a bare macOS run re-execs itself once with it set,
        # through the same launch form `Child.argv` uses (the process may be a `ruby -e` child,
        # whose `$PROGRAM_NAME` is not a script). Linux has no Objective-C
        # runtime, so this never runs there.
        def reexec_with_fork_safety
          return unless RUBY_PLATFORM.include?("darwin") && !ENV["OBJC_DISABLE_INITIALIZE_FORK_SAFETY"]

          ENV["OBJC_DISABLE_INITIALIZE_FORK_SAFETY"] = "YES"
          exec(*Child.argv(@root, "qa_tick"))
        end

        # **Loaded once, here.** The three steps each `require "hecks"` (plus their own era and
        # fuzzing extras) at their own top. Loading the union up front means every `fork` below
        # hands its step an already-booted Ruby with Bundler's gems already activated and each of
        # these files already in `$LOADED_FEATURES`, so the step's own `require` lines are no-ops
        # instead of a second, third, and fourth cold load of the whole runtime.
        def load_steps
          $LOAD_PATH.unshift File.join(@root, "lib")
          STEP_LIBRARIES.each { |library| require library }
        end

        def git(*)
          out, err, status = Open3.capture3("git", *, chdir: @repo_dir)
          [out.strip, err.strip, status]
        end

        def banner(title)
          puts
          puts "── #{title} " + ("─" * [0, 70 - title.size].max)
          puts
        end

        def refuse_unless_ready
          require_clean_tree
          rebase_on_origin_main
        end

        def require_clean_tree
          banner "worktree (#{@repo_dir})"
          dirty, err, status = git("status", "--porcelain")
          abort "refused: could not read git status at #{@repo_dir} — #{err}" unless status.success?
          refuse_dirty_tree(dirty) unless dirty.empty?
          puts "clean"
        end

        def refuse_dirty_tree(dirty)
          abort "refused: the working tree is dirty — a tick starts from a clean checkout, never over " \
                "uncommitted work:\n#{dirty}"
        end

        def rebase_on_origin_main
          banner "git fetch origin && git rebase origin/main"
          out, err, status = git("fetch", "origin")
          abort "refused: git fetch origin failed — #{err.empty? ? out : err}" unless status.success?
          out, err, status = git("rebase", "origin/main")
          abort_rebase(out, err) unless status.success?
          head, = git("rev-parse", "--short", "HEAD")
          puts "at #{head}"
        end

        def abort_rebase(out, err)
          git("rebase", "--abort")
          abort "refused: git rebase origin/main stopped (aborted, tree restored) — #{err.empty? ? out : err}"
        end
      end
    end
  end
end
