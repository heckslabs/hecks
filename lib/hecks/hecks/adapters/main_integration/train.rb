# frozen_string_literal: true

require "json"
require_relative "../console_capture"

module Hecks
  module Adapters
    class MainIntegration
      # The push train's own copy (`~/.claude/hecks-train`), as a boarding uses it: brought up to
      # origin/main when it has no tracked changes, then asked to board the checkout's main. The
      # train runs in its own process and store, so what it pushed is read from its answer. The
      # command line is fixed: no plain push, no force, no skipped hook, no owner override.
      class Train
        # Where the train's copy is.
        ROOT = File.join(Dir.home, ".claude", "hecks-train")

        # The statuses of a boarding the remote holds: pushed now, carried by an earlier push, or
        # queued as a pull request, where CI judges it before the merge.
        BOARDED = %w[pushed carried queued].freeze

        # Where the launcher's JSON answer starts in what it printed.
        RECORD_START = /^\{/

        # How much of a record that will not parse a refusal carries: its tail, bounded so a long
        # answer never fills the message.
        RAW_KEPT = 300

        # @param runner [#call] takes `(argv, chdir:)` and answers `[ok, output]`
        # @param root [String] the train's copy
        def initialize(runner, root: ROOT)
          @runner = runner
          @root = root
        end

        # Brings the copy to the commit being boarded, so the train runs the shape files it is about
        # to push. A landing not yet on origin/main is held by the repository the copy is a
        # worktree of, so the commit itself is checked out, never origin/main. A copy already there
        # is left alone, tracked changes or not.
        #
        # @param landed [String] the commit being boarded
        # @return [String] where the copy stands: already at the commit, or moved from one to it
        # @raise [ConsoleCapture::Failure] naming why the copy could not be brought to the commit
        def refresh(landed)
          before = head_of("HEAD")
          target = head_of("#{landed}^{commit}")
          cannot!(landed, "the commit is not in the train copy") if target.empty?
          return "train copy already at #{short(target)}" if before == target

          move_to(landed, target)
          "refreshed the train from #{short(before)} to #{short(target)}"
        end

        # @param checkout [String] the checkout whose main is boarded
        # @param commit [String, nil] the verified commit when it is not the head of main; the
        #   head is boarded when nil
        # @return [Array<String>] the command line the boarding runs
        def command(checkout, commit: nil)
          [File.join(@root, "exe", "hecks"), "SendTrain.board!", "checkout=#{checkout}", "remote=origin", "branch=main",
           *("commit=#{commit}" if commit), "--confirm", "--wait"]
        end

        # @param checkout [String] the checkout whose main is boarded
        # @param commit [String, nil] the verified commit when it is not the head of main
        # @return [Hash{String => Object}] the boarding's record as the train answered it
        # @raise [ConsoleCapture::Failure] when the train refused, faulted or answered unreadably
        def board(checkout, commit: nil)
          ok, output = run(*command(checkout, commit: commit))
          state = record_in(output)
          return state if ok && BOARDED.include?(state["status"].to_s)

          raise ConsoleCapture::Failure, "the push train did not push: #{state["refusal"] || output.to_s.strip[-300..] || output}"
        end

        private

        def run(*argv) = @runner.call(argv, chdir: @root)

        def head_of(rev) = run("git", "rev-parse", "--verify", "-q", rev).last.strip

        def short(sha) = sha.to_s[0, 10]

        def move_to(landed, target)
          dirty = !run("git", "status", "--porcelain", "--untracked-files=no").last.strip.empty?
          cannot!(landed, "the train copy has tracked changes") if dirty
          ok, said = run("git", "checkout", "-q", "--detach", landed)
          cannot!(landed, tail(said, 120)) unless ok
          cannot!(landed, "it stayed at #{short(head_of("HEAD"))}") unless head_of("HEAD") == target
        end

        def cannot!(landed, why)
          raise ConsoleCapture::Failure, "boarding waits: the train could not be refreshed to #{short(landed)}: #{why}"
        end

        # The record's state, empty when the train printed no record. A record that will not parse
        # raises carrying its last {RAW_KEPT} characters, where the train writes its refusal, so the
        # reason is never lost behind an empty state.
        def record_in(output)
          text = output.to_s
          start = text.index(RECORD_START)
          start ? JSON.parse(text[start..]).fetch("state", {}) : {}
        rescue JSON::ParserError => e
          raise ConsoleCapture::Failure,
                "the push train answered a record that could not be read (#{tail(e.message, 80)}): " \
                "#{tail(text[start..], RAW_KEPT)}"
        end

        # The last `size` characters of a text, marked when it was cut: a parse error quotes the
        # whole text it read, and neither may fill a refusal.
        def tail(text, size)
          flat = text.strip.tr("\n", " ")
          flat.length > size ? "…#{flat[-size..]}" : flat
        end
      end
    end
  end
end
