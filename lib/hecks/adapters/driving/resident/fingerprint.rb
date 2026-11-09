module Hecks
  module Adapters
    module Driving
      module Resident
        # What a resident was built from, as a cheap listing: each file's path, size and
        # modification time under `lib/` and under any other domain directory it has loaded, plus
        # the lockfile. Taking it costs a stat per file, not a digest of the bytes, so a resident
        # can check it on every line. A change in the listing means the loaded declarations may be
        # out of date, and the resident retires.
        class Fingerprint
          # The declaration files outside `lib/` a loaded domain directory contributes.
          DECLARATIONS = "*.{bluebook,world,hecksagon,adapter,behaviors,examples,rb}".freeze
          # Files at the checkout's root that change what loads.
          ROOT_FILES = %w[Gemfile Gemfile.lock hecks.gemspec].freeze

          # @param root [String] the checkout
          def initialize(root)
            @root = root
            @directories = []
          end

          # Adds a domain directory outside `lib/` to what is listed.
          def watch(directory)
            @directories |= [directory] unless directory.start_with?(File.join(@root, "lib/"))
          end

          # @return [Integer] a value that differs whenever the listing does
          def current
            paths = Dir.glob(File.join(@root, "lib", "**", "*")) + ROOT_FILES.map { |file| File.join(@root, file) }
            paths += @directories.flat_map { |dir| Dir.glob(File.join(dir, "**", DECLARATIONS)) }
            paths.filter_map { |path| entry(path) }.sort_by(&:first).hash
          end

          private

          def entry(path)
            stat = File.stat(path)
            [path, stat.size, stat.mtime] if stat.file?
          rescue SystemCallError
            nil
          end
        end
      end
    end
  end
end
