# Hecks::AI::IDE::ScreenshotHandler
#
# Saves IDE screenshots to timestamped files. Keeps last 20.
#
#   handler = ScreenshotHandler.new("/path/to/project")
#   handler.save(base64_data)
#   handler.latest_path  # => ".claude/ide/screenshots/20260402_140800.png"
#
require "base64"
require "fileutils"

module Hecks
  module AI
    module IDE
      class ScreenshotHandler
        attr_reader :latest_path

        def initialize(project_dir)
          @dir = File.join(project_dir, ".claude", "ide", "screenshots")
          @latest_path = nil
        end

        def save(base64_data)
          FileUtils.mkdir_p(@dir)
          png = Base64.decode64(base64_data)
          ts = Time.now.strftime("%Y%m%d_%H%M%S")
          @latest_path = File.join(@dir, "#{ts}.png")
          File.binwrite(@latest_path, png)
          File.binwrite(File.join(@dir, "latest.png"), png)
          prune
        end

        private

        def prune
          shots = Dir[File.join(@dir, "*.png")]
            .reject { |f| f.end_with?("latest.png") }.sort
          shots[0...-20].each { |f| File.delete(f) } if shots.size > 20
        end
      end
    end
  end
end
