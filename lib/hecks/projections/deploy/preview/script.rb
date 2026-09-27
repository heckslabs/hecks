require "erb"

module Hecks
  module Projections
    module Deploy
      module Preview
        # Renders `preview.sh` from `preview.sh.erb`, kept as a separate file so `bash -n`
        # and `shellcheck` can read it; every baked-in value already passed `Settings`.
        module Script
          TEMPLATE = File.join(__dir__, "preview.sh.erb").freeze

          module_function

          def render(settings)
            ERB.new(File.read(TEMPLATE), trim_mode: "-").result_with_hash(
              s: settings, image_hint: image_hint(settings)
            )
          end

          # Names the local images `deploy` expects, for the script's header.
          def image_hint(settings)
            settings.containers.map(&:image).join(", ")
          end
        end
      end
    end
  end
end
