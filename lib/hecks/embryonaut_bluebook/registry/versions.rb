module Hecks
  module EmbryonautBluebook
    class Registry
      # A package's versions: the one its manifest says, the release tags it has, and which of two
      # is newer. Included in `Registry`.
      module Versions
        # The `version:` line of a `bluebook.yml`, capturing the version.
        VERSION_LINE = /^version: *(.*)$/

        # A run of digits or a run of anything else: the parts `sort -V` compares.
        VERSION_PART = /\d+|\D+/

        # A version part that is a number.
        NUMERIC_PART = /\A\d/

        private

        def manifest_version(package)
          file = File.join(@root, package, "bluebook.yml")
          File.file?(file) ? File.read(file)[VERSION_LINE, 1] : nil
        end

        def tags(package) = @source.tags("#{package}-v*")

        def latest_version(package)
          tags(package).map { |tag| tag.delete_prefix("#{package}-v") }.max_by { |version| order(version) }
        end

        # The greater of two versions, compared as `sort -V` does: runs of digits as numbers.
        def newest(left, right) = [left, right].max_by { |version| order(version) }

        def order(version)
          version.scan(VERSION_PART).map { |part| part.match?(NUMERIC_PART) ? [0, part.to_i, ""] : [1, 0, part] }
        end
      end
    end
  end
end
