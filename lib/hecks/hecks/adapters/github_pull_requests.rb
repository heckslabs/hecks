# frozen_string_literal: true

require "json"
require "open3"
require_relative "console_capture"

module Hecks
  module Adapters
    # The `GitHubPullRequests` port's adapter: opens, squash-merges and reads pull requests of the
    # repository the current directory is in, through `gh`.
    #
    # The aggregate has already recorded the request. Nothing here decides whether a pull request
    # should be opened or merged; it only asks GitHub and reports what GitHub answered. A merge is
    # always a squash, and `--admin` is never passed, so a branch protection rule is not bypassed.
    class GithubPullRequests
      # A pull request number: digits only.
      NUMBER = /\A\d+\z/

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      # @param runner [#call, nil] runs `gh` with its arguments, answering `[stdout, stderr, success]`;
      #   the real `gh` when nil. A spec replaces it.
      def initialize(aggregate: nil, settings: {}, root: nil, runner: nil)
        @runner = runner || method(:run_gh)
      end

      # Opens a pull request from a branch onto a base, its title and body taken from the commits.
      #
      # @param held [Hash] the `PullRequest` record: `branch` (required), `base` (`main` when absent)
      # @return [Hash{Symbol => Hash}] `outcome:` (`opened`), `number:`, `url:` and `report:`
      # @raise [ConsoleCapture::Failure] when no branch is named, or GitHub refuses
      def create(**held)
        branch = plain(held[:branch]) or raise ConsoleCapture::Failure, "no branch to open a pull request from"
        base = plain(held[:base]) || "main"
        out = gh!("pr", "create", "--head", branch, "--base", base, "--fill")
        url = pull_request_url(out)
        number = url&.split("/")&.last
        raise ConsoleCapture::Failure, "gh pr create printed no pull request URL: #{out.strip.inspect}" unless number

        { outcome: { value: "opened" }, number: { value: number }, url: { value: url },
          report: { value: "opened ##{number} from #{branch} onto #{base}: #{url}" } }
      end

      # Squash-merges one open pull request by its number.
      #
      # @param held [Hash] the `PullRequest` record: `number` (required)
      # @return [Hash{Symbol => Hash}] `outcome:` (`merged`), `number:` and `report:`
      # @raise [ConsoleCapture::Failure] when no number is named, or GitHub refuses
      def squash(**held)
        number = pull_request_number(held[:number], "merge")
        gh!("pr", "merge", number, "--squash")

        { outcome: { value: "merged" }, number: { value: number },
          report: { value: "squash-merged ##{number}" } }
      end

      # The state of one pull request, as text: its number, state, URL and checks.
      #
      # @param held [Hash] the query's arguments: `number` (required)
      # @return [Hash{Symbol => String}] `text:` one `name: value` line each
      # @raise [ConsoleCapture::Failure] when no number is named, or GitHub refuses
      def status(**held)
        number = pull_request_number(held[:number], "read")
        view = JSON.parse(gh!("pr", "view", number, "--json", "number,state,url,mergedAt,statusCheckRollup"))
        { text: "#{status_lines(view).join("\n")}\n" }
      end

      private

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument

      # A pull request's number, digits only: gh reads a value that starts with a dash as an option.
      def pull_request_number(argument, verb)
        number = plain(argument)
        return number if number.to_s.match?(NUMBER)

        raise ConsoleCapture::Failure, "no pull request number to #{verb}, or it is not a number: #{number.inspect}"
      end

      # The first line of gh's output that is a URL; `gh pr create` prints the new pull request's.
      def pull_request_url(out) = out.lines.find { |line| line.start_with?("https://") }&.strip

      def status_lines(view)
        checks = Array(view["statusCheckRollup"]).map { |check| "#{check["name"]}=#{check_state(check)}" }
        ["number: #{view["number"]}", "state: #{view["state"]}", "url: #{view["url"]}",
         "merged: #{view["mergedAt"] || "no"}", "checks: #{checks.empty? ? "none" : checks.join(", ")}"]
      end

      # A check's conclusion once it has one, and its state while it is still pending.
      def check_state(check) = check["conclusion"].to_s.empty? ? check["state"] : check["conclusion"]

      # Runs `gh` and returns its stdout, or raises `ConsoleCapture::Failure` with its reason.
      def gh!(*arguments)
        out, err, ok = @runner.call(arguments)
        return out if ok

        raise ConsoleCapture::Failure, "gh #{arguments.first(2).join(" ")} failed: #{err.strip.empty? ? out.strip : err.strip}"
      end

      def run_gh(arguments)
        out, err, status = Open3.capture3("gh", *arguments)
        [out, err, status.success?]
      rescue Errno::ENOENT
        ["", "gh is not installed", false]
      end
    end
  end
end
