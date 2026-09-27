require "fileutils"
require_relative "../vendoring"
require_relative "lock"
require_relative "shape"

module Hecks
  module EmbryonautBluebook
    # Vendors one package of the bluebook registry into a consuming project.
    #
    # ## What it does
    #
    # Pins the package's top-level `bluebook/*.bluebook` files from one commit
    # of a local source repository into
    # `<root>/vendor/embryonaut_bluebooks/<name>/bluebook/`, where `load!`
    # resolves them. Only bluebook files are taken: a `.hecksagon`, `.port` or
    # `.adapter` is a wiring decision for whoever deploys, never part of the
    # vendored package.
    #
    # ## Releases and bare commits
    #
    # The source repository tags each release `<name>-v<X.Y.Z>` on a commit
    # whose `<name>/bluebook.yml` says that version. A release pin (`ref` nil for
    # the newest tag, `"1.2.0"`, or the tag name) also writes `bluebook.lock`,
    # which records version, tag, commit, content digest and storage shape, and
    # holds two refusals, because a production project is bound to `PostgresEra`:
    #
    # - a version lower than the vendored one, unless `allow_downgrade`;
    # - a storage-shape change that does not raise the version by at least a
    #   minor, so a new era shows in the version number and not only in a hash.
    #
    # Any other commit-ish pins that commit and writes only the marker, with no
    # lock and no version checks. Either way nothing on disk changes when a
    # pin is refused or its files do not load.
    class Vendor
      # A release version, `X.Y.Z`.
      VERSION = /\A\d+\.\d+\.\d+\z/

      # A package name is a directory name and a bluebook name stem.
      NAME = /\A[a-z][a-z0-9_]*\z/

      # What a vendoring changed.
      #
      # @!attribute [r] previous_version
      #   @return [String, nil] the version recorded before, nil when there was none
      # @!attribute [r] previous_shape
      #   @return [Array<String>, nil] the shape lines measured before, nil when there was
      #   no earlier copy
      Result = Struct.new(:package, :commit, :version, :tag, :digest, :shape,
                          :previous_version, :previous_shape, :dir, keyword_init: true) do
        # Says whether this was a release pin, which writes a lock.
        #
        # @return [Boolean] true for a release, false for a bare commit
        def release? = !tag.nil?

        # Says whether the storage shape moved since the earlier copy.
        #
        # @return [Boolean] true when an earlier copy existed and its shape differs
        def shape_changed? = !previous_shape.nil? && previous_shape != shape
      end

      # @param name [String, Symbol] the package's directory name, such as `"payments"`
      # @param from [String] path of the local source repository
      # @param ref [String, nil] `X.Y.Z`, a release tag name, any commit-ish, or nil for the
      #   newest release
      # @param root [String] the consuming project's root
      # @param allow_downgrade [Boolean] whether a release older than the vendored one is allowed
      # @raise [Vendoring::Error] if the name is not a plain package name
      def initialize(name, from:, root:, ref: nil, allow_downgrade: false)
        @name = name.to_s
        raise Vendoring::Error, "#{name.inspect} is not a package name" unless @name.match?(NAME)

        @source = Vendoring::GitSource.new(from)
        @ref = ref&.to_s
        @root = root
        @allow_downgrade = allow_downgrade
      end

      # Pins the package and reports what changed.
      #
      # @return [Result] the commit, version and shape now vendored
      # @raise [Vendoring::Error] if the release or commit is not found, the tagged commit
      #   disagrees with its own version, the files do not load, or a refusal above applies
      def call
        tag, version = release
        previous_version, previous_shape = existing
        shape = nil
        pin = Vendoring.pin(from: @source.path, ref: tag || @ref, subtree: "#{@name}/bluebook",
                            into: package_dir, glob: "*.bluebook") do |staged, commit|
          shape = Shape.labels(staged)
          next nil unless tag

          refuse_unless_acceptable!(version, previous_version, previous_shape, shape)
          { "bluebook.lock" => lock(version, tag, commit, staged, shape).to_s }
        end
        build_result(pin, tag, version, shape, previous_version, previous_shape)
      end

      private

      def package_dir = File.join(@root, "vendor", "embryonaut_bluebooks", @name)

      # Resolves what `ref` asks for into a release tag and its version.
      #
      # @return [Array(String, String), nil] tag and version for a release, nil for a bare commit
      def release
        tag = release_tag
        return nil unless tag

        version = tag.delete_prefix("#{@name}-v")
        tagged = @source.read(tag, "#{@name}/bluebook.yml")&.[](/^version: *(\S+)/, 1)
        unless tagged == version
          raise Vendoring::Error, "#{tag} points at a commit whose bluebook.yml says version #{tagged.inspect}"
        end

        [tag, version]
      end

      def release_tag
        return newest_release_tag if @ref.nil?
        return existing_tag("#{@name}-v#{@ref}") if @ref.match?(VERSION)

        @ref.match?(/\A#{Regexp.escape(@name)}-v\d+\.\d+\.\d+\z/) ? existing_tag(@ref) : nil
      end

      def newest_release_tag
        tags = release_tags
        raise Vendoring::Error, "no #{@name}-v* release tag in #{@source.path}" if tags.empty?

        "#{@name}-v#{tags.max_by { |version| Gem::Version.new(version) }}"
      end

      def existing_tag(tag)
        return tag if release_tags.include?(tag.delete_prefix("#{@name}-v"))

        raise Vendoring::Error, "no release #{tag} in #{@source.path} (releases: #{release_tags.sort_by do |v|
          Gem::Version.new(v)
        end.join(' ')})"
      end

      def release_tags
        @source.tags("#{@name}-v*").map { |tag| tag.delete_prefix("#{@name}-v") }.grep(VERSION)
      end

      # The version and storage shape of what is vendored now, measured from
      # its files as they stand rather than read back, so a copy vendored before
      # locks existed still gets a real "before".
      def existing
        version = Lock.read(File.join(package_dir, "bluebook.lock"))&.version
        dir = File.join(package_dir, "bluebook")
        shape = File.directory?(dir) ? Shape.labels(dir) : nil
        [version, shape]
      rescue Vendoring::Error
        [version, nil]
      end

      def refuse_unless_acceptable!(version, previous_version, previous_shape, shape)
        return unless previous_version

        refuse_downgrade!(version, previous_version)
        return if previous_shape.nil? || previous_shape == shape
        return if minor_or_more?(previous_version, version)

        raise Vendoring::Error,
              "#{@name} #{previous_version} -> #{version} changes the storage shape but is only a patch bump " \
              "(before: #{previous_shape.join(' ')}; after: #{shape.join(' ')}). Raise the package's version " \
              "by at least a minor in the source repository and release again. Nothing was changed."
      end

      def refuse_downgrade!(version, previous_version)
        return if @allow_downgrade || Gem::Version.new(version) >= Gem::Version.new(previous_version)

        raise Vendoring::Error, "#{@name} #{previous_version} is vendored; #{version} is older. " \
                                "Pass allow_downgrade to do it anyway."
      end

      def minor_or_more?(old, new)
        old_major, old_minor = old.split(".").map(&:to_i)
        new_major, new_minor = new.split(".").map(&:to_i)
        new_major > old_major || (new_major == old_major && new_minor > old_minor)
      end

      def lock(version, tag, commit, staged, shape)
        Lock.new(package: @name, version: version, tag: tag, commit: commit,
                 digest: Lock.digest_of(staged), shape: shape)
      end

      def build_result(pin, tag, version, shape, previous_version, previous_shape)
        Result.new(package: @name, commit: pin.commit, version: version, tag: tag,
                   digest: Lock.digest_of(pin.dir), shape: shape, dir: pin.dir,
                   previous_version: previous_version, previous_shape: previous_shape)
      end
    end
  end
end
