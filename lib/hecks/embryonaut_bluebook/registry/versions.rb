module Hecks
  module EmbryonautBluebook
    class Registry
      # A package's versions: the one its manifest says, the release tags it has, and which of two
      # is newer. Included in `Registry`.
      module Versions
        private

        def manifest_version(package)
          file = File.join(@root, package, "bluebook.yml")
          File.file?(file) ? File.read(file)[/^version: *(.*)$/, 1] : nil
        end

        def tags(package) = @source.tags("#{package}-v*")

        def latest_version(package)
          tags(package).map { |tag| tag.delete_prefix("#{package}-v") }.max_by { |version| order(version) }
        end

        # The greater of two versions, compared as `sort -V` does: runs of digits as numbers.
        def newest(left, right) = [left, right].max_by { |version| order(version) }

        def order(version) = version.scan(/\d+|\D+/).map { |part| part.match?(/\A\d/) ? [0, part.to_i, ""] : [1, 0, part] }
      end
    end
  end
end
