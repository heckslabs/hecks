require "json"
require_relative "commands"
require_relative "git"
require_relative "clean_tree"
require_relative "../lane"

module Hecks
  module Release
    class Runner
      # The checks that run before a release does anything: tools installed, a
      # clean current release lane (`stable`), matching versions, and a changelog entry.
      class Preflight
        # What the checks learned; `sha` is also `origin/<release lane>`, enforced by check_current.
        Facts = Struct.new(:version, :sha, keyword_init: true)

        INSTALL_HINTS = {
          "git"  => "install git",
          "gem"  => "install Ruby, which ships gem",
          "npm"  => "install Node.js: brew install node",
          "curl" => "install curl",
          "op"   => "install the 1Password CLI: brew install 1password-cli"
        }.freeze
        VERSION_LINE = /^\s*VERSION\s*=\s*"(?<version>[^"]+)"/
        CLIENT_PACKAGE = "packages/hecks-client/package.json".freeze
        HOST_RELEASE_FILE = "rust/host/HECKS_RELEASE".freeze

        def initialize(root:, commands:, git:, tools:)
          @root = root
          @commands = commands
          @git = git
          @tools = tools
        end

        # Refuses when a tool the release runs is not installed.
        #
        # @return [void]
        # @raise [Refusal] naming the tool and how to install it
        def check_tools!
          check_tools
        end

        # Runs every check; the first refusal stops it.
        def check!
          check_tools
          check_branch
          check_current
          check_clean
          version = declared_version
          check_client_version(version)
          check_host_release(version)
          check_changelog(version)
          Facts.new(version: version, sha: git("rev-parse", "HEAD").strip)
        end

        private

        def check_tools
          @tools.each do |tool|
            next if @commands.capture(tool, "--version").success?

            raise Refusal, "#{tool} not found on PATH; #{INSTALL_HINTS.fetch(tool, "install #{tool}")}"
          end
        end

        def check_branch
          branch = git("rev-parse", "--abbrev-ref", "HEAD").strip
          return if branch == lane

          raise Refusal, "on branch #{branch}, not #{lane}; release from #{lane}: git checkout #{lane}"
        end

        def check_current
          fetch = @git.capture("fetch", "origin")
          raise Refusal, "git fetch origin failed (#{fetch.stderr.strip}); check the network and the remote" unless fetch.success?

          head = git("rev-parse", "HEAD").strip
          upstream = git("rev-parse", "origin/#{lane}").strip
          return if head == upstream

          raise Refusal, "#{lane} (#{head[0, 7]}) is not origin/#{lane} (#{upstream[0, 7]}); " \
                         "wait for the release commit to be promoted, then git pull --ff-only"
        end

        # The lane a release is cut from: the one that feeds a tag, never the one that takes
        # pushes with no gate.
        def lane = @lane ||= Lane.release

        def check_clean
          unless git("status", "--porcelain").strip.empty?
            raise Refusal, "the working tree has uncommitted changes; commit or discard them before releasing"
          end

          CleanTree.new(git: @git).check!
        end

        def declared_version
          match = File.read(File.join(@root, "lib/hecks/version.rb")).match(VERSION_LINE)
          raise Refusal, "lib/hecks/version.rb declares no VERSION; restore it" unless match

          match[:version]
        end

        def check_client_version(version)
          client = JSON.parse(File.read(File.join(@root, CLIENT_PACKAGE))).fetch("version")
          return if client == version

          raise Refusal, "packages/hecks-client is at #{client} but Hecks::VERSION is #{version}; bump the package first."
        end

        # The Rust host reports the Hecks release it was built for from this file, and the
        # committed-approval gate compares rehearsals against it.
        def check_host_release(version)
          path = File.join(@root, HOST_RELEASE_FILE)
          host = File.exist?(path) ? File.read(path).strip : nil
          return if host == version

          raise Refusal, "#{HOST_RELEASE_FILE} says #{host.inspect} but Hecks::VERSION is #{version}; " \
                         "write #{version} into it in the release PR."
        end

        def check_changelog(version)
          return if File.read(File.join(@root, "CHANGELOG.md")).match?(/^## \[#{Regexp.escape(version)}\]/)

          raise Refusal, "CHANGELOG.md has no `## [#{version}]` heading; add the release entry in the release PR"
        end

        def git(*)
          @git.read(*)
        end
      end
    end
  end
end
