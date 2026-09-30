require_relative "commands"
require "hecks/hecks/adapters/codebase/gem_registry"
require "hecks/hecks/adapters/codebase/npm_registry"

module Hecks
  module Release
    class Runner
      # Asks the registries whether a version is already out, so a re-run of the
      # release skips what an earlier run finished.
      #
      # Neither question needs credentials. The registries themselves are the GemRegistry and
      # NpmRegistry adapters.
      class Published
        # @param root [String] the repository root
        # @param commands [#capture] runs curl and npm
        def initialize(root:, commands:)
          @gems = Hecks::Adapters::Codebase::GemRegistry.new(root: root, commands: commands)
          @npm = Hecks::Adapters::Codebase::NpmRegistry.new(root: root, commands: commands)
        end

        # Says whether RubyGems lists the hecks gem at a version.
        #
        # @param version [String] the version to look for
        # @return [Boolean] true when it is published
        # @raise [Refusal] if RubyGems cannot be reached or answers with something unreadable
        def gem?(version) = @gems.published?(version)

        # Says whether npm lists @hecks/client at a version.
        #
        # @param version [String] the version to look for
        # @return [Boolean] true when it is published
        # @raise [Refusal] if npm fails for any reason other than the version not existing
        def npm?(version) = @npm.published?(version)
      end
    end
  end
end
