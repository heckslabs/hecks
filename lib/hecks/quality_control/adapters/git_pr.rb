# frozen_string_literal: true

require "open3"
require "json"

module Hecks
  module Adapters
    # The `GitPr` port's adapter: the `git` and `gh` calls behind a pull request the QA practice
    # opens or checks, and the two rules that need the outside world to answer.
    #
    # The rules a ledger record can answer (the branch prefix, the bug being fixed, the angle
    # being under investigation) are `given`s on `Patch.Open` and `Improvement.Open`. The two
    # here need the repository or a count of today's pull requests: the per-day cap and the fix
    # commit being an ancestor of `HEAD`.
    class GitPr
      # A rule the adapter enforces refused the request; nothing was opened.
      class Refusal < StandardError; end

      # `git` or `gh` could not do what was asked, whatever the request.
      class CommandFailed < StandardError; end

      # A commit sha as it may be handed to `git` as a revision.
      SHA_PATTERN = /\A[0-9a-fA-F]{7,40}\z/

      # The remote a branch is pushed to and `gh pr create --head` reads it from.
      REMOTE = "origin"

      # What `gh pr view` says when the branch simply has no pull request.
      NO_PR = /no pull requests? found/i

      # The fields `gh pr view` is asked for when a PR is opened or looked up by branch.
      VIEW_FIELDS = "number,url,headRefName,headRefOid,title,state"

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      # @param repo_dir [String] the checkout `git` and `gh` run in; `QA_REPO_DIR` picks one so a
      #   spec can use a throwaway repository and a fake `gh`
      def initialize(aggregate: nil, settings: {}, root: nil, repo_dir: ENV.fetch("QA_REPO_DIR", Dir.pwd))
        @repo_dir = repo_dir
      end

      # @return [String] the checkout's current branch
      # @raise [Refusal] when the directory is not a git checkout
      def branch
        out, _err, status = git("rev-parse", "--abbrev-ref", "HEAD")
        raise Refusal, "not a git checkout at #{@repo_dir}" unless status.success?

        out
      end

      # @return [String] the commit `HEAD` names
      def head = git("rev-parse", "HEAD").first

      # Refuses a checkout with uncommitted work, since a PR opened from it would not carry it.
      #
      # @return [void]
      # @raise [Refusal] when `git status` cannot be read or reports changes
      def assert_clean_tree!
        dirty, _err, status = git("status", "--porcelain")
        raise Refusal, "could not read git status at #{@repo_dir}" unless status.success?
        return if dirty.empty?

        raise Refusal, "the working tree at #{@repo_dir} is dirty — commit or discard first:\n#{dirty}"
      end

      # Refuses one more pull request than the day's cap allows; a cap of zero is no cap.
      #
      # @param opened_today [Integer] how many PRs the ledger recorded since local midnight
      # @param cap [Integer] `PR_CAP_PER_DAY`
      # @return [void]
      # @raise [Refusal] when `opened_today` has reached a positive `cap`
      def assert_under_daily_cap!(opened_today:, cap:)
        return unless cap.positive? && opened_today >= cap

        raise Refusal, "#{opened_today} PR(s) already opened since local midnight, and " \
                       "QualityControlDials::PR_CAP_PER_DAY is #{cap} — leave this as an open Bug/Angle " \
                       "and open it tomorrow, or raise the dial in qa/settings.yml"
      end

      # Refuses a fix commit that is not part of the branch being opened.
      #
      # @param commit [String] the commit the ledger says fixes the bug
      # @param owner [String] what the commit belongs to, worded into the refusal (`"BUG#1"`)
      # @return [void]
      # @raise [Refusal] when `commit` is not a sha or not an ancestor of `HEAD`
      def assert_ancestor!(commit:, owner:)
        assert_sha!(commit, owner)
        _out, _err, status = git("merge-base", "--is-ancestor", "--", commit, "HEAD")
        return if status.success?

        raise Refusal, "#{owner}'s own fix commit #{commit[0, 7]} is not an ancestor of HEAD " \
                       "(#{head[0, 7]}) on #{branch} — the PR must carry the commit the ledger says fixes it"
      end

      # Refuses a fix commit that the pushed branch does not carry: `gh pr create --head` opens
      # the pull request from the remote branch, not from the local checkout.
      #
      # @param branch [String] the head branch
      # @param commit [String] the commit the ledger says fixes the bug
      # @param owner [String] what the commit belongs to, worded into the refusal
      # @return [void]
      # @raise [Refusal] when the branch is not on the remote, or its tip does not carry `commit`
      def assert_pushed!(branch:, commit:, owner:)
        assert_sha!(commit, owner)
        out, err, status = git("ls-remote", "--heads", REMOTE, "refs/heads/#{branch}")
        raise Refusal, "could not read #{REMOTE} for #{branch}: #{err}" unless status.success?

        tip = out.split.first.to_s
        raise Refusal, "#{branch} is not pushed to #{REMOTE} — push it before opening the PR" if tip.empty?

        assert_carries!(tip, commit, owner, "the pushed #{REMOTE}/#{branch}")
      end

      # Refuses a pull request whose head does not carry the fix commit.
      #
      # @param head [String] the PR's head commit, as `gh` reports it
      # @param commit [String] the commit the ledger says fixes the bug
      # @param owner [String] what the commit belongs to, worded into the refusal
      # @return [void]
      # @raise [Refusal] when `head` is not a sha, or does not carry `commit`
      def assert_pr_head!(head:, commit:, owner:)
        assert_sha!(commit, owner)
        assert_sha!(head, "the PR head")
        assert_carries!(head, commit, owner, "the PR head")
      end

      # The open PR for a branch.
      #
      # @param branch [String] the head branch
      # @return [Hash{Symbol => Object}, nil] `gh pr view`'s fields, or nil when no PR is open
      # @raise [CommandFailed] when `gh` failed for any reason but the branch having no PR
      def open_pull_request(branch)
        out, err, status = gh("pr", "view", branch, "--json", VIEW_FIELDS)
        unless status.success?
          return nil if err.match?(NO_PR)

          raise CommandFailed, "gh pr view #{branch} failed — #{err.empty? ? out : err}"
        end

        view = JSON.parse(out, symbolize_names: true)
        view[:state] == "OPEN" ? view : nil
      end

      # Opens a PR from `branch`.
      #
      # @param branch [String] the head branch
      # @param title [String] the PR's title
      # @param body [String] the PR's description
      # @param draft [Boolean] open it as a draft
      # @return [String] what `gh pr create` printed, the PR's URL
      # @raise [CommandFailed] when `gh` refuses
      def create_pull_request(branch:, title:, body:, draft: false)
        args = ["pr", "create", "--head", branch, "--title", title, "--body", body]
        args << "--draft" if draft
        out, err, status = gh(*args)
        raise CommandFailed, "gh pr create failed — #{err.empty? ? out : err}" unless status.success?

        out
      end

      # Queues a squash merge for when the PR's checks pass.
      #
      # @param number [Integer] the PR's number
      # @return [void]
      # @raise [CommandFailed] when `gh` refuses
      def merge_when_green(number)
        _out, err, status = gh("pr", "merge", number.to_s, "--auto", "--squash")
        raise CommandFailed, "gh pr merge --auto failed — #{err}" unless status.success?
      end

      # A tracked PR's state and head commit, read live: a push mints a new commit to clear.
      #
      # @param number [Integer] the PR's number
      # @return [Hash{Symbol => Object}] `state`, `headRefOid` and `url`
      # @raise [CommandFailed] when `gh` cannot read it
      def pull_request(number)
        parse(gh("pr", "view", number.to_s, "--json", "state,headRefOid,url"), "gh pr view failed")
      end

      # A tracked PR's checks, as `gh` reports them.
      #
      # @param number [Integer] the PR's number
      # @return [Array<Hash{Symbol => Object}>] each check's `name`, `state`, `bucket`, `workflow`
      # @raise [CommandFailed] when `gh` cannot read them
      def checks(number)
        parse(gh("pr", "checks", number.to_s, "--json", "name,state,bucket,workflow"), "gh pr checks failed")
      end

      private

      def assert_sha!(value, owner)
        return if value.to_s.match?(SHA_PATTERN)

        raise Refusal, "#{owner}'s commit #{value.to_s.inspect} does not look like a sha"
      end

      def assert_carries!(tip, commit, owner, label)
        _out, _err, status = git("merge-base", "--is-ancestor", "--", commit, tip)
        return if status.success?

        raise Refusal, "#{owner}'s own fix commit #{commit[0, 7]} is not an ancestor of #{label} " \
                       "(#{tip[0, 7]}) — the PR must carry the commit the ledger says fixes it"
      end

      def parse(result, failure)
        out, err, status = result
        raise CommandFailed, "#{failure} — #{err.strip.empty? ? out.strip : err.strip}" unless status.success?

        JSON.parse(out, symbolize_names: true)
      end

      def git(*) = run_tool("git", *)

      def gh(*) = run_tool("gh", *)

      def run_tool(tool, *)
        out, err, status = Open3.capture3(tool, *, chdir: @repo_dir)
        [out.strip, err.strip, status]
      rescue Errno::ENOENT
        raise Refusal, "#{tool} is not installed or not on PATH (or #{@repo_dir} is missing) — " \
                       "the practice cannot open or check a pull request without it"
      end
    end
  end
end
