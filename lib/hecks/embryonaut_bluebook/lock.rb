require "digest"

module Hecks
  module EmbryonautBluebook
    # What a vendored package records about the release it came from:
    # `vendor/embryonaut_bluebooks/<name>/bluebook.lock`.
    #
    # ## File format
    #
    # One `key: value` line each for `package`, `version`, `tag`, `commit`
    # and `digest`, then one `shape: <Domain> <label>` line per domain:
    #
    #     package: payments
    #     version: 1.2.0
    #     tag: payments-v1.2.0
    #     commit: <full commit id the tag points at>
    #     digest: <sha256 of the vendored *.bluebook files>
    #     shape: Payments d33c23
    #
    # The digest is the sha256 of the `<sha256>  <name>` lines of every
    # top-level `*.bluebook` file, sorted by name. The source repository's own
    # `bin/bluebook_digest` prints the same number for the tagged release, which
    # is how a vendored copy is proven to be exactly what it claims to be.
    Lock = Struct.new(:package, :version, :tag, :commit, :digest, :shape, keyword_init: true) do
      # Computes the content digest of a directory's `*.bluebook` files.
      #
      # @param dir [String] the directory to measure
      # @return [String, nil] 64 lowercase hex characters, nil when the directory holds
      #   no bluebook file
      def self.digest_of(dir)
        names = Dir.children(dir).select { |name| name.end_with?(".bluebook") }.sort
        return nil if names.empty?

        lines = names.map { |name| "#{Digest::SHA256.file(File.join(dir, name)).hexdigest}  #{name}\n" }
        Digest::SHA256.hexdigest(lines.join)
      end

      # Reads a lock file.
      #
      # @param path [String] the `bluebook.lock` path
      # @return [Lock, nil] the parsed lock, nil when the file does not exist
      def self.read(path)
        return nil unless File.file?(path)

        parse(File.read(path))
      end

      # Parses a lock's text.
      #
      # @param text [String] the file's content
      # @return [Lock] the lock, with `shape` as an Array of lines (empty when none)
      def self.parse(text)
        fields = { shape: [] }
        text.each_line do |line|
          key, _, value = line.chomp.partition(": ")
          next if key.empty?

          key == "shape" ? fields[:shape] << value : fields[key.to_sym] = value
        end
        new(**fields.slice(*members))
      end

      # Renders the lock as the text written to `bluebook.lock`.
      #
      # @return [String] the lines described above, newline terminated
      def to_s
        header = %i[package version tag commit digest].map { |key| "#{key}: #{self[key]}\n" }
        (header + Array(shape).map { |line| "shape: #{line}\n" }).join
      end
    end
  end
end
