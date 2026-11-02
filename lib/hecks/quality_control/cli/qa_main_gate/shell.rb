# frozen_string_literal: true

require "open3"

module Hecks
  module QualityControlCli
    class QaMainGate
      # The commands outside the ledger that a red-main fix runs: the mechanical fixer, the landing,
      # and the
      # push through the push train. Each answers its output and whether it exited 0.
      module Shell
        # The push train's own launcher, in its detached checkout.
        TRAIN_LAUNCHER = File.expand_path("~/.claude/hecks-train/exe/hecks")

        module_function

        # Applies `rubocop -a` to the files, which fixes what it can; whether the rest is fixed is
        # the gate's
        # to say.
        #
        # @return [Array(String, Boolean)]
        def rubocop(dir, files)
          run("bundle", "exec", "rubocop", "-a", *files, chdir: dir)
        end

        # Lands a branch on local main, through the launcher of the checkout.
        #
        # @return [Array(String, Boolean)]
        def land(root, branch)
          run(File.join(root, "exe/hecks"), "landing.land!", "checkout.value=#{root}", "branch.value=#{branch}",
              "--confirm", "--wait", chdir: root)
        end

        # Pushes main through the push train.
        #
        # @return [Array(String, Boolean)]
        def push(root)
          run(TRAIN_LAUNCHER, "SendTrain.board!", "checkout=#{root}", "remote=origin", "branch=main",
              "--confirm", "--wait", chdir: root)
        end

        def run(*argv, chdir:)
          output, status = Open3.capture2e(*argv, chdir: chdir)
          [output, status.success?]
        end
      end
    end
  end
end
