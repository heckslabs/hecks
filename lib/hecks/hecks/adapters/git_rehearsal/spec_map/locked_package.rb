# frozen_string_literal: true

module Hecks
  module Adapters
    class GitRehearsal
      class SpecMap
        # The package directory a changed path sits in, found by its lock file.
        #
        # A vendored release holds a `bluebook.lock` that pins a digest of its files, so a change to
        # any file beneath the lock's directory breaks the lock. The directory is named by the lock
        # itself, not by a spec naming convention, so a package added later is found as well.
        module LockedPackage
          # The file that marks a directory as a locked package.
          LOCK = "bluebook.lock"

          module_function

          # @param root [String] the tree
          # @param path [String] a changed path relative to the root
          # @return [String, nil] the nearest ancestor directory of the path that holds a lock,
          #   relative to the root, or nil when the path sits under none
          def of(root, path)
            dir = File.dirname(path)
            until dir == "."
              return dir if File.file?(File.join(root, dir, LOCK))

              dir = File.dirname(dir)
            end
            nil
          end
        end
      end
    end
  end
end
