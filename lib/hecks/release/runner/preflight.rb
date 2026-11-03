require_relative "commands"

module Hecks
  module Release
    class Runner
      # The one check a release makes for itself: the tools it runs are installed.
      #
      # Every rule about the tree (branch, lane, clean, versions, changelog, approval, tag) is a
      # given
      # of `PublishingRun.Accept`, judged before a release is carried out and passed in as `Facts`;
      # none is repeated here.
      class Preflight
        # What the rules cleared; `sha` is also `origin/<release lane>`, enforced by `Accept`.
        Facts = Struct.new(:version, :sha, keyword_init: true)

        INSTALL_HINTS = {
          "git"  => "install git",
          "gem"  => "install Ruby, which ships gem",
          "npm"  => "install Node.js: brew install node",
          "curl" => "install curl",
          "op"   => "install the 1Password CLI: brew install 1password-cli"
        }.freeze

        # @param commands [#capture] starts each process
        # @param tools [Array<String>] the programs the release runs
        def initialize(commands:, tools:)
          @commands = commands
          @tools = tools
        end

        # Refuses when a tool the release runs is not installed.
        #
        # @return [void]
        # @raise [Refusal] naming the tool and how to install it
        def check_tools!
          @tools.each do |tool|
            next if @commands.capture(tool, "--version").success?

            raise Refusal, "#{tool} not found on PATH; #{INSTALL_HINTS.fetch(tool, "install #{tool}")}"
          end
        end
      end
    end
  end
end
