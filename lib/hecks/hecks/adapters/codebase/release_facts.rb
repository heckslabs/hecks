# frozen_string_literal: true

require "json"
require "hecks/release/runner"
require "hecks/release/lane"
require_relative "tree"
require_relative "../console_capture"

module Hecks
  module Adapters
    module Codebase
      # The facts a release is judged by, read from git and the checkout's files and judged by
      # nothing here: the rules are the givens of the `Clear` command of `PublishingRun`.
      #
      # It reads the branch, the lane a release is cut from (the `Lane` row that feeds a tag),
      # whether `HEAD` is that lane's `origin/` branch (after a fetch), whether the tree is
      # clean, the gem's version and the client package's, whether the changelog has a heading for
      # the version, and where a tag for the version already points. Nothing is changed but the
      # remote-tracking refs a fetch updates.
      class ReleaseFacts
        # The line of `lib/hecks/version.rb` that declares the version.
        VERSION_LINE = /^\s*VERSION\s*=\s*"(?<version>[^"]+)"/

        # Where the client package declares its version, relative to the checkout.
        CLIENT_PACKAGE = "packages/hecks-client/package.json"

        # @param tree [Tree] the checkout
        # @param commands [#capture, #run!] starts each process, as `Release::Runner::Commands` does
        def initialize(tree, commands:)
          @tree = tree
          @git = Release::Runner::Git.new(root: tree.root, commands: commands)
        end

        # Reads the facts a run of the operation needs.
        #
        # @param operation [String] `publish` (every fact) or `publish_gem` (the versions only)
        # @return [Hash] each fact as the run holds it: every one a value object
        #   as a hash, and `ships_from` the checkout's path
        # @raise [ConsoleCapture::Failure] when git or a file cannot be read
        def gather(operation)
          version = declared_version
          facts = { operation: word(operation), version: word(version), client_version: word(client_version),
                    ir_version: word("#{Bluebook::Chapter::IR_VERSION}.0.0"), ships_from: { path: @tree.root } }
          return facts if operation == "publish_gem"

          facts.merge(git_facts(version)).merge(changelog: flag(changelog?(version)))
        rescue Release::Runner::Refusal, Errno::ENOENT, JSON::ParserError, KeyError => e
          raise ConsoleCapture::Failure, e.message
        end

        private

        def git_facts(version)
          fetch_origin!
          head = read("rev-parse", "HEAD")
          lane_facts(head).merge(clean:     flag(read("status", "--porcelain").empty?),
                                 tag_state: word(tag_state("v#{version}", head)))
        end

        def fetch_origin!
          fetch = @git.capture("fetch", "origin")
          raise ConsoleCapture::Failure, "git fetch origin failed (#{fetch.stderr.strip})" unless fetch.success?
        end

        # Where the checkout stands against the lane a release is cut from.
        def lane_facts(head)
          lane = Release::Lane.release
          { branch: word(read("rev-parse", "--abbrev-ref", "HEAD")), head: word(head), release_lane: word(lane),
            on_origin: flag(head == read("rev-parse", "origin/#{lane}")) }
        end

        def tag_state(tag, head)
          tagger = Release::Runner::Tagger.new(git: @git, console: nil, dry_run: true)
          commits = [tagger.local_commit(tag), tagger.remote_commit(tag)].compact
          return "none" if commits.empty?

          commits.all?(head) ? "at_release_commit" : "elsewhere"
        end

        def read(*) = @git.read(*).strip

        def declared_version
          match = File.read(@tree.path("lib/hecks/version.rb")).match(VERSION_LINE)
          raise Release::Runner::Refusal, "lib/hecks/version.rb declares no VERSION; restore it" unless match

          match[:version]
        end

        def client_version = JSON.parse(File.read(@tree.path(CLIENT_PACKAGE))).fetch("version")

        def changelog?(version)
          File.read(@tree.path("CHANGELOG.md")).match?(/^## \[#{Regexp.escape(version)}\]/)
        end

        def word(text) = { value: text }

        def flag(truth) = { value: truth }
      end
    end
  end
end
