module Hecks
  module EmbryonautBluebook
    class Vendor
      # The refusals a release pin passes through: a downgrade, and a storage-shape change that is
      # only a patch bump. Included in `Vendor`.
      module Acceptance
        private

        def refuse_unless_acceptable!(version, previous, shape)
          return unless previous.version

          refuse_downgrade!(version, previous.version)
          return if previous.shape.nil? || previous.shape == shape
          return if minor_or_more?(previous.version, version)

          raise Vendoring::Error,
                "#{@name} #{previous.version} -> #{version} changes the storage shape but is only a patch bump " \
                "(before: #{previous.shape.join(" ")}; after: #{shape.join(" ")}). Raise the package's version " \
                "by at least a minor in the source repository and release again. Nothing was changed."
        end

        def refuse_downgrade!(version, previous_version)
          return if @allow_downgrade || Gem::Version.new(version) >= Gem::Version.new(previous_version)

          raise Vendoring::Error, "#{@name} #{previous_version} is vendored; #{version} is older. " \
                                  "Pass allow_downgrade (ALLOW_DOWNGRADE=1 on the command line) to do it anyway."
        end

        def minor_or_more?(old, new)
          old_major, old_minor = old.split(".").map(&:to_i)
          new_major, new_minor = new.split(".").map(&:to_i)
          new_major > old_major || (new_major == old_major && new_minor > old_minor)
        end
      end
    end
  end
end
