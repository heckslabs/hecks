require "digest"

module Hecks
  module EmbryonautBluebook
    # The digest here must match the source repo's own bin/bluebook_digest
    # output for the same tag, or a vendored copy cannot be trusted.
    Lock = Struct.new(:package, :version, :tag, :commit, :digest, :shape, keyword_init: true) do
      # Sorted by name so the digest never depends on directory listing order.
      def self.digest_of(dir)
        names = Dir.children(dir).select { |name| name.end_with?(".bluebook") }.sort
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
        header = %i[package version tag commit digest].map { |key| "#{key}: #{self[key]}\n" }
        (header + Array(shape).map { |line| "shape: #{line}\n" }).join
      end
    end
  end
end
