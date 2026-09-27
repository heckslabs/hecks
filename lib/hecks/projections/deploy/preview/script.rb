require "erb"

module Hecks
  module Projections
    module Deploy
      module Preview
        # Renders `preview.sh`, the script that creates, updates and deletes one
        # branch's preview stack.
        #
        # The script text lives in `preview.sh.erb` beside this file because it
        # is a shell program, not Ruby: keeping it as a file lets `bash -n` and
        # `shellcheck` read it as one. Every value baked into it has already
        # passed `Settings`' patterns, so the template never quotes defensively.
        module Script
          TEMPLATE = File.join(__dir__, "preview.sh.erb").freeze

          module_function

          # Renders the script.
          #
          # @param settings [Settings] the resolved preview settings
          # @return [String] the bash script, ending in one newline
          def render(settings)
            ERB.new(File.read(TEMPLATE), trim_mode: "-").result_with_hash(
              s: settings, image_hint: image_hint(settings)
            )
          end

          # Names the local images `deploy` expects, for the script's header.
          #
          # @param settings [Settings] the resolved preview settings
          # @return [String] the image references, comma separated
          def image_hint(settings)
            settings.containers.map(&:image).join(", ")
          end
        end
      end
    end
  end
end
