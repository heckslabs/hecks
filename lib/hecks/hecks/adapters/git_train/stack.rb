# frozen_string_literal: true

require "json"
require_relative "reading"
require_relative "rate_limit_retry"

module Hecks
  module Adapters
    class GitTrain
      # Where a boarding of main stands among the train pull requests still in CI. A boarding while
      # none is open is built on the remote's main. A boarding while one is open is stacked on it:
      # built on that train's head, its own pull request still into main, so the merge queue tests
      # it on top of the earlier entry. At the cap of open trains a boarding is refused by name and
      # pushes nothing, and one whose commit is not built on the open train's head is refused too.
      #
      # An open train counts only while the remote's main does not hold its head, and a retried
      # boarding's own branch never counts. When the open trains cannot be read, the boarding is
      # built on the remote's main, as when none is open, and its placing says why.
      class Stack
        include Reading

        # How many train pull requests may be in CI at once.
        CAP = 2

        # The head branch prefix of a train pull request.
        PREFIX = "train/main-"

        # One read of the open pull requests, the newest hundred.
        LIST = ["api", "repos/{owner}/{repo}/pulls?state=open&per_page=100"].freeze

        # A boarding's place: the commit it is built on, the open train beneath it (`number`,
        # `branch` and `head`, nil when there is none) and what the read said, for the report.
        Placing = Struct.new(:base, :beneath, :note) do
          # @return [String] how the boarding was placed, for its report
          def said
            return note.to_s if beneath.nil?

            "stacked on ##{beneath[:number]} (#{beneath[:branch]} at #{beneath[:head][0, 9]})"
          end
        end

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        # @param runner [#call] takes `(argv, chdir:)` and answers `[ok, output]` for `gh`
        # @param pause [#call, nil] takes the seconds to wait out a spent rate limit; a spec sets it
        def initialize(git, checkout, runner:, pause: nil)
          @git = git
          @checkout = checkout
          @runner = RateLimitRetry.new(runner, pause: pause)
        end

        # @param boarded [String] the commit to board
        # @param tracking [String] the remote-tracking main, just fetched
        # @return [Placing] the commit the boarding is built on and the train beneath it
        # @raise [ConsoleCapture::Failure] at the cap of trains in flight, or the boarded commit
        #   is not built on the open train's head
        def place(boarded, tracking)
          open, note = in_flight(boarded, tracking)
          return Placing.new(tracking, nil, note) if open.empty?

          full!(open) if open.size >= CAP
          beneath = open.last
          unstacked!(beneath, boarded) unless ancestor?(beneath[:head], boarded)
          Placing.new(beneath[:head], beneath, nil)
        end

        private

        # The open trains besides this boarding's own branch whose head main does not hold yet,
        # oldest first, and a note when they could not be read.
        def in_flight(boarded, tracking)
          own = PullRequestBoarding.branch_for(boarded)
          pulls, note = open_trains
          [pulls.reject { |pull| pull[:branch] == own || ancestor?(pull[:head], tracking) }, note]
        end

        def open_trains
          ok, output = @runner.call(["gh", *LIST], chdir: @checkout)
          return [[], "open trains unread (#{output.to_s.strip[0, 120]}); built on main"] unless ok

          [trains_in(output), nil]
        rescue JSON::ParserError => e
          [[], "open trains unread (#{e.message[0, 120]}); built on main"]
        end

        def trains_in(output)
          listed = output.to_s.strip.empty? ? [] : JSON.parse(output.to_s)
          trains = listed.select { |pull| pull.dig("head", "ref").to_s.start_with?(PREFIX) }
          trains.sort_by { |pull| pull["created_at"].to_s }.map { |pull| train(pull) }
        end

        def train(pull) = { number: pull["number"], branch: pull.dig("head", "ref"), head: pull.dig("head", "sha").to_s }

        def full!(open)
          numbers = open.map { |pull| "##{pull[:number]}" }.join(", ")
          raise ConsoleCapture::Failure, "#{open.size} trains in flight (#{numbers}): board again when one merges"
        end

        def unstacked!(beneath, boarded)
          raise ConsoleCapture::Failure,
                "the open train ##{beneath[:number]} at #{short(beneath[:head])} is not beneath " \
                "#{short(boarded)}: board again"
        end
      end
    end
  end
end
