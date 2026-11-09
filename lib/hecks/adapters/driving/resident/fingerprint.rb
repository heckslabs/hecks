module Hecks
  module Adapters
    module Driving
      module Resident
        # What a resident was built from, as a cheap listing: each file's path, size and
        # modification time under `lib/` and under any other domain directory it has loaded, the
        # files at the checkout's root that change what loads, and the launcher itself. Taking it
        # costs a stat per file, not a digest of the bytes, so a resident can check it on every
        # line. A change in the listing means the loaded declarations may be out of date, and the
        # resident retires.
        #
        # A file replaced by one of the same size whose modification time is put back (`rsync -t`,
        # an archive unpacked, a file system with coarse times) is not seen. That gap is accepted
        # (ADR 0201).
        class Fingerprint
          # The declaration files outside `lib/` a loaded domain directory contributes.
          DECLARATIONS = "*.{bluebook,world,hecksagon,adapter,behaviors,examples,rb}".freeze
          # Files at the checkout's root that change what loads.
          ROOT_FILES = %w[Gemfile Gemfile.lock hecks.gemspec exe/hecks .ruby-version].freeze
          # Declarations at the checkout's root.
          ROOT_DECLARATIONS = "*.{bluebook,world,hecksagon}".freeze

          # @param root [String] the checkout
          def initialize(root)
            @root = root
            @directories = []
            @baseline = nil
          end

          # Takes what the resident was built from, to compare with later.
          def mark! = (@baseline = listing)

          # Adds a domain directory outside `lib/` to what is listed. Its files as they are now
          # join what the resident was built from; a change to one later retires it.
          def watch(directory)
            return if directory.start_with?(File.join(@root, "lib/")) || @directories.include?(directory)

            @directories << directory
            @baseline&.merge!(entries(in_directory(directory)))
          end

          # @return [Boolean] whether anything listed has changed since {#mark!}, apart from the
          #   directories {#watch} added
          def changed? = listing != @baseline

          # @return [Integer] a value that differs whenever the listing does
          def current = listing.hash

          private

          def listing = entries(root_paths + @directories.flat_map { |dir| in_directory(dir) })

          def root_paths
            lib = Dir.glob(File.join(@root, "lib", "**", "*"), File::FNM_DOTMATCH)
            lib + ROOT_FILES.map { |file| File.join(@root, file) } + Dir.glob(File.join(@root, ROOT_DECLARATIONS))
          end

          def in_directory(dir) = Dir.glob(File.join(dir, "**", DECLARATIONS))

          def entries(paths) = paths.filter_map { |path| entry(path) }.to_h

          def entry(path)
            stat = File.stat(path)
            [path, [stat.size, stat.mtime]] if stat.file?
          rescue SystemCallError
            nil
          end
        end
      end
    end
  end
end
