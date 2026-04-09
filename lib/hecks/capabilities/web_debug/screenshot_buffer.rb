# Hecks::Capabilities::WebDebug::ScreenshotBuffer
#
# Circular buffer of screenshot frames. Saves base64 JPEG data
# to /tmp/appeal_screenshots/ with auto-cleanup of old frames.
#
#   buffer = ScreenshotBuffer.new
#   buffer.save(base64_data, timestamp)
#   buffer.latest  # => "/tmp/appeal_screenshots/frame_042.jpg"
#   buffer.count   # => 42
#
require "fileutils"
require "base64"

module Hecks
  module Capabilities
    module WebDebug
      class ScreenshotBuffer
        BUFFER_SIZE = 100
        DIR = "/tmp/appeal_screenshots"

        def initialize
          @frame_count = 0
          @mutex = Mutex.new
          FileUtils.mkdir_p(DIR)
        end

        # Save a base64-encoded frame to disk.
        #
        # @param base64_data [String] base64 JPEG data
        # @param timestamp [String] ISO timestamp
        # @return [String] path to saved file
        def save(base64_data, timestamp = nil)
          @mutex.synchronize do
            @frame_count += 1
            filename = "frame_#{@frame_count.to_s.rjust(5, "0")}.jpg"
            path = File.join(DIR, filename)
            File.binwrite(path, Base64.decode64(base64_data))
            cleanup if @frame_count > BUFFER_SIZE
            path
          end
        end

        def save_snapshot(state_json, timestamp = nil)
          @mutex.synchronize do
            @frame_count += 1
            filename = "snapshot_#{@frame_count.to_s.rjust(5, "0")}.json"
            path = File.join(DIR, filename)
            File.write(path, state_json)
            path
          end
        end

        def latest
          files = (Dir[File.join(DIR, "*.json")] + Dir[File.join(DIR, "*.jpg")]).sort
          files.last
        end

        def count
          @frame_count
        end

        private

        def cleanup
          files = Dir[File.join(DIR, "*.jpg")].sort
          excess = files.size - BUFFER_SIZE
          files.first(excess).each { |f| File.delete(f) } if excess > 0
        end
      end
    end
  end
end
