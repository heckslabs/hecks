module Hecks
  module Adapters
    module Driving
      module Resident
        # What a resident was built from, as a cheap listing: each file's path, size and
        # modification time under `lib/` and any other domain directory it has loaded, the files at
        # the checkout's root that change what loads, and the launcher. A change in the listing
        # means the loaded declarations may be out of date, and the resident retires.
        #
        # An answer is reused for {RECHECK_SECONDS}. Between full listings (every {FULL_SECONDS},
        # and whenever a look finds something different) a look re-stats the files already listed
        # and the directories that hold them, with no walk of the tree: an edit or a removal shows
        # in the file's stat, an addition in its directory's time. A file replaced by one of the
        # same size with its modification time put back is not seen (ADR 0201).
        class Fingerprint
          # The declaration files outside `lib/` a loaded domain directory contributes.
          DECLARATIONS = "*.{bluebook,world,hecksagon,adapter,behaviors,examples,rb}".freeze
          # Files at the checkout's root that change what loads.
          ROOT_FILES = %w[Gemfile Gemfile.lock hecks.gemspec exe/hecks .ruby-version].freeze
          # Declarations at the checkout's root.
          ROOT_DECLARATIONS = "*.{bluebook,world,hecksagon}".freeze
          # Directories at the checkout's root whose entries change what loads.
          ROOT_DIRECTORIES = %w[. exe].freeze
          # Seconds an answer is reused.
          RECHECK_SECONDS = 1.0
          # Seconds between full listings of the tree.
          FULL_SECONDS = 30.0

          # @param root [String] the checkout
          # @param clock [#call] the time in seconds; a spec stands in
          def initialize(root, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
            @root = root
            @clock = clock
            @directories = []
            @baseline = nil
            @looked = {}
            @changed = false
          end

          # Takes what the resident was built from, to compare with later.
          def mark!
            @changed = false
            @checked = nil
            @listed = @clock.call
            @baseline = listing
          end

          # Adds a domain directory outside `lib/` to what is listed. Its files as they are now
          # join what the resident was built from; a change to one later retires it.
          def watch(directory)
            return if directory.start_with?(File.join(@root, "lib/")) || @directories.include?(directory)

            @directories << directory
            @baseline&.merge!(entries(in_directory(directory) + folders(directory)))
          end

          # @return [Boolean] whether anything listed has changed since {#mark!}, apart from the
          #   directories {#watch} added
          def changed?
            now = @clock.call
            return @changed if @checked && now - @checked < RECHECK_SECONDS

            @checked = now
            @changed ||= moved?(now)
          end

          # @return [Integer] a value that differs whenever the listing does
          def current = listing.hash

          private

          def moved?(now)
            return true unless @baseline
            return false unless full?(now) || looks_different?

            @listed = now
            listing != @baseline
          end

          def full?(now) = now - @listed >= FULL_SECONDS

          def looks_different?
            @baseline.any? { |path, (size, mtime)| differs?(path, size, mtime) } ||
              @looked.any? { |dir, mtime| differs?(dir, nil, mtime) }
          end

          def differs?(path, size, mtime)
            stat = File.stat(path)
            (size && stat.size != size) || stat.mtime != mtime
          rescue SystemCallError
            true
          end

          def listing
            @looked = {}
            entries(root_paths + @directories.flat_map { |dir| in_directory(dir) + folders(dir) })
          end

          def root_paths
            lib = Dir.glob(File.join(@root, "lib", "**", "*"), File::FNM_DOTMATCH)
            root = ROOT_FILES.map { |file| File.join(@root, file) } + Dir.glob(File.join(@root, ROOT_DECLARATIONS))
            lib + root + ROOT_DIRECTORIES.map { |dir| File.join(@root, dir) } + [File.join(@root, "lib")]
          end

          def in_directory(dir) = Dir.glob(File.join(dir, "**", DECLARATIONS))

          # A loaded domain directory and the directories under it, whose times show a file added.
          def folders(dir) = [dir, *Dir.glob(File.join(dir, "**", "*/"))]

          # The files among the paths with their size and time. The directories among them are
          # kept apart, with their time, for the looks between full listings.
          def entries(paths) = paths.each_with_object({}) { |path, found| note(path, found) }

          def note(path, found)
            stat = File.stat(path)
            if stat.directory?
              @looked[path] = stat.mtime
            elsif stat.file?
              found[path] = [stat.size, stat.mtime]
            end
          rescue SystemCallError
            nil
          end
        end
      end
    end
  end
end
