# frozen_string_literal: true

require "json"
require_relative "reading"

module Hecks
  module Adapters
    class GitTrain
      # Whether the commit a train carries is the one the landing's quick gate passed: the tip is
      # the commit the landing's gate marker names as green (`hecks-local-main-gate.json`, in the
      # repository's common git directory) and it descends from the remote's main. It passes on
      # those two facts and judges no commit of the range: the gate ran on the tip's whole tree,
      # whichever landings or adoptions put its commits there. A finish writes the marker for the
      # tip it leaves on main, so a tip that is not the latest finish gets no mark.
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
        # @return [Boolean] whether the marker names the tip green and the tip holds remote main
        def landed?(tip, base) = marked?(tip) && ancestor?(base, tip)

        # `-c hecks.trainLanded=<commit>` marks a push whose tip the landing's quick gate passed;
        # the pre-push hook checks the marker itself before it trusts the mark.
        #
        # @param branch [String] the branch boarded
        # @param remote [String] the remote it is pushed to
        # @param tip [String] the commit the train carries
        # @return [Array<String>] the `git -c` words, empty when the tip is not landed
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

        def common_dir = read("rev-parse", "--path-format=absolute", "--git-common-dir")
      end
    end
  end
end
