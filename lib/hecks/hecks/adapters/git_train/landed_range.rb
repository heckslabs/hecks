# frozen_string_literal: true

require "json"
require_relative "reading"

module Hecks
  module Adapters
    class GitTrain
      # Whether the commit a train carries was judged by the landing's quick gate: the facts are
      # read here and the rule is deliberate in this adapter, since no domain command carries
      # a train's commits. A range qualifies when every first-parent commit it holds is a merge
      # (a hand commit does not) and the tip is the commit the landing's gate marker names as
      # green (`hecks-local-main-gate.json`, in the repository's common git directory).
      #
      # The marker certifies the quick stage only; it says nothing of the drift checks, which a
      # boarding still runs.
      class LandedRange
        include Reading

        # The landing's gate marker, written after the quick gate passed on the commit main names.
        MARKER = "hecks-local-main-gate.json"

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        def initialize(git, checkout)
          @git = git
          @checkout = checkout
        end

        # @param tip [String] the commit the train carries
        # @param base [String] the ref the remote's main is read at
        # @return [Boolean] whether every commit of the range is a landed merge and the tip passed
        def landed?(tip, base) = marked?(tip) && merges_only?(tip, base)

        # `-c hecks.trainLanded=<commit>` marks a push whose commits the landing's quick gate
        # judged; the pre-push hook checks the marker itself before it trusts the mark.
        #
        # @param branch [String] the branch boarded
        # @param remote [String] the remote it is pushed to
        # @param tip [String] the commit the train carries
        # @return [Array<String>] the `git -c` words, empty when the range is not landed
        def config(branch, remote, tip)
          return [] unless branch == "main" && landed?(tip, "#{remote}/main")

          ["-c", "hecks.trainLanded=#{tip}"]
        end

        private

        def marked?(tip)
          marker = JSON.parse(File.read(File.join(common_dir, MARKER)))
          marker["verdict"] == "green" && marker["sha"] == tip
        rescue SystemCallError, JSON::ParserError
          false
        end

        def merges_only?(tip, base)
          lone = read("rev-list", "--first-parent", "--no-merges", "#{base}..#{tip}")
          lone.empty? && ancestor?(base, tip)
        end

        def common_dir = read("rev-parse", "--path-format=absolute", "--git-common-dir")
      end
    end
  end
end
