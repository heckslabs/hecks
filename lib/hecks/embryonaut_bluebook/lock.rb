require "digest"

module Hecks
  module EmbryonautBluebook
    # The digest here must match the source repo's own bin/bluebook_digest
    # output for the same tag, or a vendored copy cannot be trusted.
    Lock = Struct.new(:package, :version, :tag, :commit, :digest, :shape, :format, keyword_init: true) do
      # What a package's `bluebook/` directory ships and a project vendors: its bluebooks, and the
      # plugin adapters and wasm modules that answer their queries. Format 1, the default, and the
      # digest `bin/bluebook_digest` in each registry package computes.
      self::PACKAGE_FILES = "*.{bluebook,adapter,wasm}".freeze

      # Format 2 also covers the hecksagons and worlds that wire a bluebook, so a changed wiring
      # file is caught by the digest rather than loaded unchecked. It names itself `format: 2`.
      self::PACKAGE_FILES_V2 = "*.{bluebook,adapter,wasm,hecksagon,world}".freeze

      # Sorted by name so the digest never depends on directory listing order.
      def self.digest_of(dir, glob: self::PACKAGE_FILES)
        names = Dir.children(dir).select { |name| File.fnmatch(glob, name, File::FNM_EXTGLOB) }.sort
        return nil if names.empty?

        lines = names.map { |name| "#{Digest::SHA256.file(File.join(dir, name)).hexdigest}  #{name}\n" }
        Digest::SHA256.hexdigest(lines.join)
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
        keys = self[:format] ? %i[package version tag commit digest format] : %i[package version tag commit digest]
        header = keys.map { |key| "#{key}: #{self[key]}\n" }
        (header + Array(shape).map { |line| "shape: #{line}\n" }).join
      end
    end
  end
end
