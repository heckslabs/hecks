require "open3"
require "tmpdir"
require "fileutils"
require_relative "../vendoring"
require_relative "lock"
require_relative "registry/changelog"
require_relative "registry/versions"

module Hecks
  module EmbryonautBluebook
    # A bluebook registry repository, judged and released: packages at `<name>/bluebook.yml`, each
    # with `<name>/bluebook/*.bluebook` and a `<name>/CHANGELOG.md`, released as the annotated tag
    # `<name>-vX.Y.Z`.
    #
    # `check` is the rule that a package's bluebook files may not change without a version bump and
    # a changelog entry; `release` is the sequence of refusals before a tag is made. A package's
    # files are compared through `Lock.digest_of`, the digest a consuming project locks.
    class Registry
      include Changelog
      include Versions

      # A version a package may carry, `X.Y.Z`.
      VERSION = /\A\d+\.\d+\.\d+\z/

      # A package name is a directory name.
      NAME = /\A[a-z][a-z0-9_]*\z/

      # What `check` found, in package order: a note for a package that has no release yet and a
      # sentence for each fault.
      class Report
        # @return [Array<String>] each fault as `<package>: <why>`
        attr_reader :failures

        def initialize
          @lines = []
          @failures = []
        end

        # @param text [String] a fact about a package that is no fault
        # @return [void]
        def note(text) = @lines << "note #{text}"

        # @param text [String] a fault, as `<package>: <why>`
        # @return [void]
        def fault(text)
          @failures << text
          @lines << "FAIL #{text}"
        end

        # @return [Boolean] whether no package is at fault
        def ok? = @failures.empty?

        # @return [String] the notes and faults in package order, then `versions ok` if none
        def to_s = (@lines + (ok? ? ["versions ok"] : [])).join("\n")
      end

      # What a release made.
      Tagged = Struct.new(:tag, :commit, keyword_init: true) do
        # @return [String] the report, ending in the command that publishes the tag
        def to_s = "Tagged #{tag} at #{commit}. Publish it with:\n  git push origin #{tag}"
      end

      # @param root [String] the registry's working tree
      # @raise [Vendoring::Error] if `root` is not a git repository
      def initialize(root)
        @root = File.expand_path(root.to_s)
        @source = Vendoring::GitSource.new(@root)
        raise Vendoring::Error, "#{@root} is not a git repository" unless git("rev-parse", "--git-dir").last.success?
      end

      # Judges every package against its latest release.
      #
      # A package fails when its `bluebook.yml` has no `X.Y.Z` version or names another package,
      # when a release tag points at a commit whose `bluebook.yml` says another version, or when
      # its bluebook files differ from the latest release's without a newer version and a
      # `CHANGELOG.md` entry for it.
      #
      # @return [Report] what was found
      def check
        report = Report.new
        packages.each { |package| check_package(package, report) }
        report
      end

      # Tags a package's current version, after the refusals that stand between a version and a
      # release: the tag exists, the version is not newer, the changelog has no entry, the package
      # has uncommitted changes, or its bluebook files are those of the latest release. Nothing is
      # pushed.
      #
      # @param package [String] the package name
      # @return [Tagged] the tag made and the commit it stands on
      # @raise [Vendoring::Error] with the first refusal
      def release(package)
        version = releasable_version(package)
        tag = "#{package}-v#{version}"
        refuse_release!(package, version, tag)
        create_tag(package, version, tag)
      end

      private

      def releasable_version(package)
        fault!("#{package.inspect} is not a package name") unless package.to_s.match?(NAME)
        version = manifest_version(package) or fault!("no #{package}/bluebook.yml")
        fault!("#{package}/bluebook.yml: version '#{version}' is not X.Y.Z") unless version.match?(VERSION)
        version
      end

      def create_tag(package, version, tag)
        notes = changelog_section(package, version)
        _, _, status = git("tag", "-a", tag, "-m", "#{package} #{version}", "-m", notes)
        raise Vendoring::Error, "git could not tag #{tag}" unless status.success?

        Tagged.new(tag: tag, commit: git("rev-parse", "--short", "HEAD").first.strip)
      end

      def packages
        Dir.glob(File.join(@root, "*", "bluebook.yml")).map { |file| File.basename(File.dirname(file)) }.sort
      end

      def check_package(package, report)
        version = manifest_version(package).to_s
        unless version.match?(VERSION)
          report.fault "#{package}: version '#{version}' is not X.Y.Z"
          return
        end
        check_name(package, report)
        tags(package).each { |tag| check_tag(package, tag, report) }
        latest = latest_version(package)
        return report.note("#{package}: no release tag yet (#{version} unreleased)") unless latest

        check_changes(package, version, latest, report)
      end

      def check_name(package, report)
        name = File.read(File.join(@root, package, "bluebook.yml"))[/^name: *(.*)$/, 1]
        report.fault "#{package}: bluebook.yml name does not match the directory" unless name == package
      end

      def check_tag(package, tag, report)
        tagged = @source.read(tag, "#{package}/bluebook.yml").to_s[/^version: *(.*)$/, 1].to_s
        return if tagged == tag.delete_prefix("#{package}-v")

        report.fault "#{package}: #{tag} points at a commit whose bluebook.yml says '#{tagged}'"
      end

      def check_changes(package, version, latest, report)
        return if released_digest(package, latest) == current_digest(package)

        if version == latest || newest(latest, version) != version
          report.fault "#{package}: bluebook files changed since #{package}-v#{latest} but " \
                       "bluebook.yml is still #{version}; bump it"
        end
        return if changelog_entry?(package, version)

        report.fault "#{package}: CHANGELOG.md has no '## #{version}' entry"
      end

      def refuse_release!(package, version, tag)
        fault!("#{tag} already exists") if git("rev-parse", "-q", "--verify", "refs/tags/#{tag}").last.success?

        latest = latest_version(package)
        fault!("#{version} is not newer than the latest release #{latest}") if latest && newest(latest, version) != version
        fault!("#{package}/CHANGELOG.md has no '## #{version}' entry") unless changelog_entry?(package, version)
        fault!("#{package} has uncommitted changes; commit them first") unless clean?(package)
        refuse_unchanged!(package, latest)
      end

      def refuse_unchanged!(package, latest)
        return unless latest && released_digest(package, latest) == current_digest(package)

        fault!("the bluebook files are identical to #{package}-v#{latest}; nothing to release")
      end

      def fault!(why) = raise(Vendoring::Error, why)

      def clean?(package) = git("status", "--porcelain", "--", package).first.strip.empty?

      def current_digest(package)
        dir = File.join(@root, package, "bluebook")
        File.directory?(dir) ? Lock.digest_of(dir) : nil
      end

      # The digest of a package's bluebook files as a release tag holds them.
      def released_digest(package, version)
        tag = "#{package}-v#{version}"
        files = @source.files(tag, "#{package}/bluebook", "*.bluebook")
        return nil if files.empty?

        Dir.mktmpdir("hecks-registry") do |scratch|
          @source.export(tag, files, scratch)
          Lock.digest_of(File.join(scratch, package, "bluebook"))
        end
      end

      def git(*) = Open3.capture3(Vendoring::GitEnvironment.clean, "git", "-C", @root, *)
    end
  end
end
