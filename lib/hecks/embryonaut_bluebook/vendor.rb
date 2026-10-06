require "fileutils"
require_relative "../vendoring"
require_relative "lock"
require_relative "shape"
require_relative "vendor/acceptance"

module Hecks
  module EmbryonautBluebook
    # Pins a package's `bluebook/*.bluebook` files from a source repo commit; a
    # release pin also refuses a downgrade or an era-breaking storage-shape change.
    class Vendor
      include Acceptance

      # A release version, `X.Y.Z`.
      VERSION = /\A\d+\.\d+\.\d+\z/

      # A package name is a directory name and a bluebook name stem.
      NAME = /\A[a-z][a-z0-9_]*\z/

      # What a vendoring changed; previous_version/previous_shape are nil when
      # there was no earlier vendored copy.
      Result = Struct.new(:package, :commit, :version, :tag, :digest, :shape,
                          :previous_version, :previous_shape, :dir, keyword_init: true) do
        def release? = !tag.nil?

        def shape_changed? = !previous_shape.nil? && previous_shape != shape
      end

      # The version and storage shape already vendored; nil for each when there is no earlier copy.
      Previous = Struct.new(:version, :shape)

      # `ref` accepts `X.Y.Z`, a release tag name, any commit-ish, or nil for
      # the newest release.
      def initialize(name, from:, root:, ref: nil, allow_downgrade: false)
        @name = name.to_s
        raise Vendoring::Error, "#{name.inspect} is not a package name" unless @name.match?(NAME)

        @source = Vendoring::GitSource.new(from)
        @ref = ref&.to_s
        @root = root
        @allow_downgrade = allow_downgrade
      end

      # Pins the package and reports what changed.
      def call
        tag, version = release
        previous = Previous.new(*existing)
        pin, shape = pin_files(tag, version, previous)
        build_result(pin, tag, version, shape, previous)
      end

      private

      def package_dir = File.join(@root, "vendor", "embryonaut_bluebooks", @name)

      # @return [Array(Vendoring::Pin, Array<String>)] what was pinned, and the storage shape staged
      def pin_files(tag, version, previous)
        shape = nil
        pin = Vendoring.pin(from: @source.path, ref: tag || @ref, subtree: "#{@name}/bluebook",
                            into: package_dir, glob: "*.bluebook") do |staged, commit|
          shape = Shape.labels(staged)
          next nil unless tag

          refuse_unless_acceptable!(version, previous, shape)
          { "bluebook.lock" => lock(version, tag, commit, staged, shape).to_s }
        end
        [pin, shape]
      end

      # Resolves what `ref` asks for into a release tag and its version, or nil
      # for a bare commit.
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
        end.join(" ")})"
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

      def lock(version, tag, commit, staged, shape)
        Lock.new(package: @name, version: version, tag: tag, commit: commit,
                 digest: Lock.digest_of(staged), shape: shape)
      end

      def build_result(pin, tag, version, shape, previous)
        Result.new(package: @name, commit: pin.commit, version: version, tag: tag,
                   digest: Lock.digest_of(pin.dir), shape: shape, dir: pin.dir,
                   previous_version: previous.version, previous_shape: previous.shape)
      end
    end
  end
end
