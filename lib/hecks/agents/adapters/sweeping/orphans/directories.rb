# frozen_string_literal: true

require "fileutils"

module Hecks
  module Adapters
    class Sweeping
      class Orphans
        # The rehearsal push directories a sweep may delete.
        #
        # A directory is stale when nothing inside it, however deep, changed for a day and no
        # process has it, or a directory below it, as its working directory. When the working
        # directories cannot be read, nothing is stale: a directory is never deleted from under a
        # process it cannot rule out.
        class Directories
          # @param roots [Array<String>] the temp directories searched for rehearsal directories
          # @param marker [String] the name a rehearsal directory starts with
          # @param age [Numeric] how long a directory must stand unchanged, in seconds
          # @param now [Time] what ages are counted back from
          # @param cwds [#call] answers every process's working directory, nil when unreadable
          def initialize(roots:, marker:, age:, now:, cwds:)
            @roots = roots
            @marker = marker
            @age = age
            @now = now
            @cwds = cwds
          end

          # @return [Array<String>] the stale directories
          def stale
            aged = candidates.select { |path| @now - newest(path) > @age }
            return aged if aged.empty?

            busy = @cwds.call
            busy ? aged.reject { |path| busy.any? { |cwd| inside?(cwd, path) } } : []
          end

          # @return [Boolean] whether a working directory is the directory or below it, by real path
          #   (`/tmp` is a link on macOS and a process reports `/private/tmp`)
          def inside?(cwd, path)
            real = File.realpath(path)
            cwd == real || cwd.start_with?("#{real}/")
          rescue SystemCallError
            true
          end

          # Deletes one directory.
          # @param path [String] a directory from {#stale}
          # @return [String] the line that says so
          def delete(path)
            FileUtils.remove_entry(path)
            "deleted push directory  #{path}"
          end

          private

          def candidates
            @roots.flat_map { |root| Dir.glob(File.join(root, "#{@marker}*")) }.uniq.select do |path|
              File.directory?(path) && !File.symlink?(path)
            end
          end

          def newest(path)
            (mtimes(path) << File.lstat(path).mtime).max
          rescue SystemCallError
            @now
          end

          def mtimes(path)
            Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH).map { |entry| File.lstat(entry).mtime }
          end
        end
      end
    end
  end
end
