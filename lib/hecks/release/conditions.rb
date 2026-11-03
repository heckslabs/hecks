# frozen_string_literal: true

module Hecks
  module Release
    # The auto-approval conditions of a release PR, judged from facts a check has gathered.
    #
    # The names are the `ReleaseCondition` values the QualityControl bluebook declares. A release is
    # approved only when every condition holds; otherwise the first failure in the order below is
    # named, and that name is the refusal.
    module Conditions
      # The value an approval accepts.
      MET = "met"

      module_function

      # @param version [String] the version the release bumps to
      # @param stable_head [Boolean] whether the commit is on stable's head after promotion
      # @param checks_green [Boolean] whether every required check passed on the commit
      # @param changelog_dated [Boolean] whether the changelog has a dated `## [version]` heading
      # @param versions [Hash{String => String}] each version file's version, keyed by its name
      # @return [String] `met`, or the name of the first condition that failed
      def judge(version:, stable_head:, checks_green:, changelog_dated:, versions:)
        return "not_on_stable_head" unless stable_head
        return "checks_not_green" unless checks_green
        return "changelog_undated" unless changelog_dated
        return "version_mismatch" unless versions_agree?(version, versions)

        MET
      end

      # @param changelog [String] the text of the changelog
      # @param version [String] the version the release bumps to
      # @return [Boolean] whether a `## [version] - YYYY-MM-DD` heading stands in the changelog
      def changelog_dated?(changelog, version)
        changelog.match?(/^## \[#{Regexp.escape(version)}\] - \d{4}-\d{2}-\d{2}$/)
      end

      # @param version [String] the version the release bumps to
      # @param versions [Hash{String => String}] each version file's version, keyed by its name
      # @return [Boolean] whether every version file names the same version
      def versions_agree?(version, versions)
        versions.any? && versions.values.all?(version)
      end
    end
  end
end
