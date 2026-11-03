# frozen_string_literal: true

require "hecks/vocabulary"

module Hecks
  module Release
    # The conditions of a release, judged from facts a check has gathered, and the one reading of a
    # checkout's files that every judge of a release shares.
    #
    # The names are the `ReleaseCondition` values the QualityControl bluebook declares. A release is
    # approved only when every condition holds; otherwise the first failure in the order below is
    # named, and that name is the refusal. The version files are the `ReleaseFile` rows of the
    # Vocabulary bluebook: `release.yml`, `publishing_run.publish` (its `Accept` command) and the
    # release PR policy all ask {unmet} and {files_agree?}, so no list of files lives anywhere else.
    module Conditions
      # The value an approval accepts.
      MET = "met"

      # The file that holds the version every other file must name.
      VERSION_FILE = "lib/hecks/version.rb"

      # The line of the version file that declares the version.
      VERSION_LINE = /^\s*VERSION\s*=\s*"([^"]+)"/

      # The `ReleaseFile` row whose lines are any (the changelog), judged by its dated heading.
      CHANGELOG = "CHANGELOG.md"

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

      # @param root [String] the checkout
      # @return [String, nil] the version `lib/hecks/version.rb` declares
      def declared_version(root)
        File.read(File.join(root, VERSION_FILE))[VERSION_LINE, 1]
      end

      # Each `ReleaseFile` row held against the version: the changelog by its dated heading, every
      # other file by the first line its row's `lines` pattern matches, which must name the version.
      #
      # @param root [String] the checkout
      # @param version [String] the version the release bumps to
      # @return [Array<String>] one sentence for each file that does not agree, empty when all do
      def unmet(root, version)
        Hecks::Vocabulary.rows("ReleaseFile").filter_map { |row| unmet_file(root, version, row) }
      end

      # @return [Boolean] whether every `ReleaseFile` row agrees with the version
      def files_agree?(root, version) = unmet(root, version).empty?

      # @return [String, nil] why one `ReleaseFile` row disagrees with the version, or nil
      def unmet_file(root, version, row)
        path = row.fetch("path")
        full = File.join(root, path)
        return "#{path} is missing" unless File.exist?(full)

        text = File.read(full)
        return changelog_unmet(text, version) if path == CHANGELOG

        named = first_version_line(text, row.fetch("lines"))
        return nil if named&.include?(version)

        "#{path} says #{named&.strip.inspect} but Hecks::VERSION is #{version}; write #{version} into it in the release PR"
      end

      # @return [String, nil] the changelog's refusal, or nil when it has a dated heading
      def changelog_unmet(text, version)
        return nil if changelog_dated?(text, version)

        "#{CHANGELOG} has no dated '## [#{version}] - YYYY-MM-DD' heading; add the release entry in the release PR"
      end

      # @return [String, nil] the first line the row's pattern matches
      def first_version_line(text, pattern)
        regex = Regexp.new(pattern)
        text.lines.map(&:chomp).find { |line| line.match?(regex) }
      end

      # Prints each unmet file and answers the exit status `release.yml` ends its step with.
      #
      # @param root [String] the checkout
      # @param out [#puts] where the words go
      # @return [Integer] 0 when every file agrees, 1 otherwise
      def check(root: Dir.pwd, out: $stdout)
        version = declared_version(root)
        if version.to_s.empty?
          out.puts "::error::#{VERSION_FILE} declares no VERSION"
          return 1
        end
        problems = unmet(root, version)
        problems.each { |problem| out.puts "::error::#{problem}" }
        out.puts "release files: every ReleaseFile row names #{version}" if problems.empty?
        problems.empty? ? 0 : 1
      end
    end
  end
end
