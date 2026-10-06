require "fileutils"

module Hecks
  module Fuzzing
    module IsolatedBoot
      # Copies a domain directory, following symlinks, together with the vendored bluebooks
      # its hecksagons name.
      module Copying
        # A vendored package named by `attaches "name", from: :vendor`.
        VENDORED_ATTACHED = /attaches\s*\(?\s*"([\w-]+)"\s*\)?\s*,\s*from:\s*:vendor/

        # Copies `source` into `destination`, following symlinks rather than reproducing
        # them (cp_r would copy a symlink as a symlink, dangling once the source tree is
        # gone), and carries any vendored bluebooks the copy's hecksagons name.
        def copy_dereferencing(source, destination)
          copy_files(source, destination)
          carry_vendored_bluebooks!(source, destination)
        end

        # Copies every file under `source` into `destination`, following symlinks.
        def copy_files(source, destination)
          FileUtils.mkdir_p(destination)
          Dir.glob(File.join(source, "**", "*"), File::FNM_DOTMATCH).each do |path|
            next if [".", ".."].include?(File.basename(path))

            copy_entry(path, File.join(destination, path.delete_prefix("#{source}/")))
          end
        end

        # Copies one file or creates one directory at `target`.
        def copy_entry(path, target)
          return FileUtils.mkdir_p(target) if File.directory?(path)

          FileUtils.mkdir_p(File.dirname(target))
          copy_if_present(path, target)
        end

        def copy_if_present(path, target)
          FileUtils.cp(path, target)
        rescue Errno::ENOENT
          # A sibling can vanish between listing and copy under parallel workers;
          # skip a file that's already gone.
        end

        # Copies vendored bluebook packages a copy's hecksagons name into the copy, since
        # `Hecks.boot` only sees the domain directory itself, not `vendor/`.
        def carry_vendored_bluebooks!(source, destination)
          names = Dir.glob(File.join(destination, "**", "*.hecksagon")).flat_map do |path|
            text = File.read(path)
            text.scan(VENDORED_ATTACHED).flatten
          end
          names.uniq.each do |name|
            package = File.join(File.dirname(source), "vendor", "embryonaut_bluebooks", name)
            next unless File.directory?(package)

            copy_files(package, File.join(File.dirname(destination), "vendor", "embryonaut_bluebooks", name))
          end
        end
      end
    end
  end
end
