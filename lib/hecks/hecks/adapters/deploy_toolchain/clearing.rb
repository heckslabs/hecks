# frozen_string_literal: true

require "fileutils"
require_relative "../console_capture"
require_relative "../world_clearing"

module Hecks
  module Adapters
    class DeployToolchain
      # The `ClearDeployment` ask: empties the `deployed_to` blocks of a domain's `.world` files, in
      # place or into a directory, and says which files and settings it removed.
      module Clearing
        # Empties every `deployed_to` block under `<domain>/bluebook/**/*.world`, through
        # `hecks deploy handover.clear`.
        #
        # With `out`, the cleared files are written there at their paths below `<domain>/bluebook/`
        # and the originals are left alone; without it they are rewritten in place. A world with
        # nothing left to clear is not rewritten and not listed.
        #
        # @param held [Hash] the `Handover` record: `domain`, and `out` when set
        # @return [Hash{Symbol => Hash}] `output:` one line per file cleared with its settings
        # @raise [ConsoleCapture::Failure] when the domain holds no `.world` file
        def clear_deployment(**held)
          bluebook = File.join(File.expand_path(plain(held[:domain])), "bluebook")
          out = plain(held[:out])
          lines = worlds_of(bluebook).filter_map { |path| clear_world(path, bluebook, out && File.expand_path(out)) }
          { output: { value: lines.empty? ? "no deployed_to settings to clear" : lines.join("\n") } }
        end

        private

        def worlds_of(bluebook)
          worlds = Dir.glob(File.join(bluebook, "**", "*.world"))
          raise ConsoleCapture::Failure, "#{bluebook} holds no .world file to clear" if worlds.empty?

          worlds
        end

        def clear_world(path, bluebook, out)
          cleared = WorldClearing.call(File.read(path))
          return unless cleared.changed?

          target = out ? File.join(out, path.delete_prefix("#{bluebook}/")) : path
          FileUtils.mkdir_p(File.dirname(target))
          File.write(target, cleared.text)
          "#{target}: cleared #{cleared.settings.join(", ")}"
        end
      end
    end
  end
end
