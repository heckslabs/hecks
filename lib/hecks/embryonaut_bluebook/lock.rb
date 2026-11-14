require "digest"

module Hecks
  module EmbryonautBluebook
    # The digest here must match the source repo's own bin/bluebook_digest
    # output for the same tag, or a vendored copy cannot be trusted.
    Lock = Struct.new(:package, :version, :tag, :commit, :digest, :shape, keyword_init: true) do
      # What a package's `bluebook/` directory ships and a project vendors: its bluebooks, the
      # ports they declare, and the adapters and wasm modules bound to them.
      self::PACKAGE_FILES = "*.{bluebook,adapter,wasm,ports.hecksagon}".freeze

      # The directory beside `bluebook/` in which a package ships the Ruby its adapters run, at
      # any depth, and the files of it a project vendors.
      self::LIBRARY = "lib".freeze
      self::LIBRARY_FILES = "*.rb".freeze

      # What vendoring exports beside `bluebook/`: each directory, and the pattern of its files.
      self::BESIDE = { self::LIBRARY => self::LIBRARY_FILES }.freeze

      # The digest of a package's `bluebook/` directory, and of the library beside it when it has
      # one. Sorted by name so it never depends on directory listing order. A package with no
      # library digests as it did before a package could carry one.
      #
      # @param dir [String] the package's `bluebook/` directory
      # @return [String, nil] the digest, or nil when the directory ships no package file
      def self.digest_of(dir)
        names = Dir.children(dir).select { |name| File.fnmatch(self::PACKAGE_FILES, name, File::FNM_EXTGLOB) }.sort
        return nil if names.empty?

        lines = names.map { |name| "#{Digest::SHA256.file(File.join(dir, name)).hexdigest}  #{name}\n" }
        Digest::SHA256.hexdigest((lines + library_lines(File.join(File.dirname(dir), self::LIBRARY))).join)
      end

      # One line for each file of a package's library, named from the package's root
      # (`lib/adapters/git.rb`), sorted; none when the package has no library.
      def self.library_lines(library)
        files = Dir.glob(File.join(library, "**", self::LIBRARY_FILES))
        files.map { |file| "#{Digest::SHA256.file(file).hexdigest}  #{self::LIBRARY}/#{file.delete_prefix("#{library}/")}\n" }
      end

      def self.read(path)
        return nil unless File.file?(path)

        parse(File.read(path))
      end

      def self.parse(text)
        fields = { shape: [] }
        text.each_line do |line|
          key, _, value = line.chomp.partition(": ")
          next if key.empty?

          key == "shape" ? fields[:shape] << value : fields[key.to_sym] = value
        end
        new(**fields.slice(*members))
      end

      def to_s
        header = %i[package version tag commit digest].map { |key| "#{key}: #{self[key]}\n" }
        (header + Array(shape).map { |line| "shape: #{line}\n" }).join
      end
    end
  end
end
