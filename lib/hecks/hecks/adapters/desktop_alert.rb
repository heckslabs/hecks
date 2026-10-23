# frozen_string_literal: true

require_relative "shell"
require_relative "console_capture"
require_relative "git"
require_relative "desktop_alert/alert"

module Hecks
  module Adapters
    # The `Alerts` port's adapter: says on the operator's desktop that a pushed branch is ready to
    # deploy. A machine with neither a notifier nor `osascript` refuses, and the push it announces
    # stands.
    #
    # The alert reads at a glance: the repository and "ready to deploy" as its title, the branch,
    # commit and how many commits went out beneath it, and the newest commits' subjects as its body.
    # Clicking it opens the branch's runs on GitHub when the remote is a GitHub repository.
    class DesktopAlert
      # How many commit subjects the body lists.
      SUBJECTS = 3

      # A GitHub remote's owner and repository, over HTTPS or SSH.
      GITHUB = %r{github\.com[:/]([^/]+)/(.+?)(?:\.git)?/?\z}

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @shell = Shell.new
        @git = Git.new
      end

      # Shows that a branch was pushed and a deploy is ready.
      #
      # @param held [Hash] the `PushTrain` record: `checkout`, `branch`, `remote`, `pushed` and
      #   `report`
      # @return [Hash{Symbol => Hash}] `report:` the alert's title and subtitle
      # @raise [ConsoleCapture::Failure] when no desktop alert could be shown
      def announce(**held)
        alert = Alert.new(title: title(held), subtitle: subtitle(held), body: body(held), link: runs(held))
        shown = alert.show(@shell)
        raise ConsoleCapture::Failure, "no desktop alert was shown: #{shown.err.strip}" unless shown.ok?

        { report: { value: "#{alert.title}: #{alert.subtitle}" } }
      end

      private

      # Named by its GitHub repository, else by the main checkout's directory: a boarding is often
      # made from a worktree, whose directory says nothing about the repository.
      def title(held)
        owner_and_name = github(held)
        "#{owner_and_name ? owner_and_name.last : main_checkout(held)} is ready to deploy"
      end

      def main_checkout(held)
        common = git(held, "rev-parse", "--path-format=absolute", "--git-common-dir")
        File.basename(common.ok? ? File.dirname(common.out.strip) : plain(held[:checkout]))
      end

      def subtitle(held)
        went_out = plain(held[:report]).to_s[/(\d+) commit/, 1]
        "#{plain(held[:remote])}/#{plain(held[:branch])} at #{plain(held[:pushed])[0, 7]}" \
          "#{" · #{went_out} new" if went_out}"
      end

      def body(held)
        listed = git(held, "log", "-#{SUBJECTS}", "--format=%s", plain(held[:pushed]))
        listed.ok? ? listed.out.lines.map { |line| "• #{line.strip}" }.join("\n") : ""
      end

      # The branch's runs on GitHub, newest first, or nil for a remote that is not on GitHub.
      def runs(held)
        owner, name = github(held)
        "https://github.com/#{owner}/#{name}/actions?query=branch%3A#{plain(held[:branch])}" if owner
      end

      # The remote's GitHub owner and repository, or nil.
      def github(held)
        url = git(held, "remote", "get-url", plain(held[:remote]))
        url.out.strip.match(GITHUB)&.captures if url.ok?
      end

      def git(held, *) = @git.capture(*, chdir: plain(held[:checkout]))

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
