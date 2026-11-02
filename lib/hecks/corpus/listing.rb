module Hecks
  module Corpus
    # How a kind's glob becomes its members: a directory each, or a file each. Extended onto `Corpus`.
    module Listing
      # @return [Array<Member>] the members of one kind: a directory each, or a file each
      # @raise [ArgumentError] if `kind` is not in `KINDS`
      def kind_members(kind, root)
        if (glob = DIRECTORY_KINDS[kind])
          directory_members(kind, root, glob)
        elsif (glob = FILE_KINDS[kind])
          file_members(kind, root, glob)
        else
          raise ArgumentError, "unknown corpus kind #{kind.inspect} — known: #{KINDS.join(", ")}"
        end
      end

      def directory_members(kind, root, glob)
        directories(root, glob).map { |dir| Member.new(File.basename(dir), kind, dir) }
      end

      def directories(root, glob) = Dir.glob(File.join(root, glob)).select { |path| File.directory?(path) }.sort

      # The part of a glob before its first wildcard.
      GLOB_FIXED_PREFIX = /\A[^*]*/

      def file_members(kind, root, glob)
        prefix = File.join(root, glob[GLOB_FIXED_PREFIX].chomp("/"))
        Dir.glob(File.join(root, glob))
           .map { |file| Member.new(file.delete_prefix("#{prefix}/").delete_suffix(".bluebook"), kind, file) }
      end
    end
  end
end
