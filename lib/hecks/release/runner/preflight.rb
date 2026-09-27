require "json"
require_relative "commands"
require_relative "git"

module Hecks
  module Release
    class Runner
      # The checks that run before a release does anything: tools installed, a
      # clean current `main`, matching versions, and a changelog entry.
      class Preflight
        # What the checks learned; `sha` is also `origin/main`, enforced by check_current.
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

        def initialize(root:, commands:, git:, tools:)
          @root = root
          @commands = commands
          @git = git
          @tools = tools
        end

        # Runs every check; the first refusal stops it.
        def check!
          check_tools
          check_branch
          check_current
          check_clean
          version = declared_version
          check_client_version(version)
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
          return if branch == "main"

          raise Refusal, "on branch #{branch}, not main; release from main: git checkout main"
        end

        def check_current
          fetch = @git.capture("fetch", "origin")
          raise Refusal, "git fetch origin failed (#{fetch.stderr.strip}); check the network and the remote" unless fetch.success?

          head = git("rev-parse", "HEAD").strip
          upstream = git("rev-parse", "origin/main").strip
          return if head == upstream

          raise Refusal, "main (#{head[0, 7]}) is not origin/main (#{upstream[0, 7]}); " \
                         "merge the release PR, then git pull --ff-only"
        end

        def check_clean
          return if git("status", "--porcelain").strip.empty?

          raise Refusal, "the working tree has uncommitted changes; commit or discard them before releasing"
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
