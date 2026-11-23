# frozen_string_literal: true

require "json"

module Hecks
  module Release
    # The bump a release cut writes: the next version in every file that names the version.
    #
    # The files are `lib/hecks/version.rb`, `rust/host/HECKS_RELEASE`, `packages/hecks-client`, the
    # README's "Current release" lines and a dated `## [X.Y.Z]` heading in `CHANGELOG.md` that takes
    # the entries under `## [Unreleased]`. It reads and writes files under one root and runs nothing.
    module Bump
      # The levels a release has, highest first.
      LEVELS = %w[major minor patch].freeze

      # The files a bump changes, relative to the checkout.
      FILES = %w[lib/hecks/version.rb rust/host/HECKS_RELEASE packages/hecks-client/package.json
                 README.md CHANGELOG.md].freeze

      module_function

      # @param current [String] a version such as `7.1.0`
      # @param level [String] `major`, `minor` or `patch`
      # @return [String] the version a release of that level follows it with
      # @raise [ArgumentError] when the level is not one of {LEVELS}
      def next_version(current, level)
        raise ArgumentError, "a release level is major, minor or patch, not #{level.inspect}" unless LEVELS.include?(level)

        major, minor, patch = current.split(".").map(&:to_i)
        { "major" => [major + 1, 0, 0], "minor" => [major, minor + 1, 0], "patch" => [major, minor, patch + 1] }
          .fetch(level).join(".")
      end

      # Writes the next version into every file and returns it.
      #
      # @param root [String] the checkout
      # @param level [String] the release's level
      # @param date [String] the heading's date, `YYYY-MM-DD`
      # @return [String] the new version
      def apply(root, level:, date:)
        version_file = File.join(root, "lib/hecks/version.rb")
        current = File.read(version_file)[/VERSION = "([^"]+)"/, 1]
        version = next_version(current, level)
        rewrite(version_file) { |text| text.sub(%(VERSION = "#{current}"), %(VERSION = "#{version}")) }
        write_others(root, current, version, date)
        version
      end

      # @return [void]
      def write_others(root, current, version, date)
        File.write(File.join(root, "rust/host/HECKS_RELEASE"), "#{version}\n")
        rewrite(File.join(root, "packages/hecks-client/package.json")) do |text|
          text.sub(/"version":\s*"#{Regexp.escape(current)}"/, %("version": "#{version}"))
        end
        rewrite(File.join(root, "README.md")) { |text| text.gsub("Current release: `#{current}`", "Current release: `#{version}`") }
        rewrite(File.join(root, "CHANGELOG.md")) { |text| heading(text, version, date) }
      end

      # @return [String] the changelog with the unreleased entries under a dated heading
      def heading(text, version, date)
        text.sub(/^## \[Unreleased\][^\n]*\n/) { "## [Unreleased]\n\n## [#{version}] - #{date}\n" }
      end

      # @return [void]
      def rewrite(path)
        File.write(path, yield(File.read(path)))
      end
    end
  end
end
