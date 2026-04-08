# Hecks::Appeal::ScreenshotBuffer
#
# Rolling buffer of browser screenshots saved to disk as JPEG.
# Maintains the last 100 frames for visual debugging. Claude
# can read these files to see the current IDE state.
#
#   buffer = Hecks::Appeal::ScreenshotBuffer.new
#   buffer.save(base64_data, "2026-04-07T12:00:00Z")
#   buffer.latest  # => "/tmp/appeal_screenshots/frame_042.jpg"
#
require "base64"
require "fileutils"

module Hecks
  module Appeal
    class ScreenshotBuffer
      BUFFER_SIZE = 100
      DIR = "/tmp/appeal_screenshots"

      def initialize
        @index = 0
        FileUtils.mkdir_p(DIR)
      end

      # Save a base64-encoded JPEG frame to the rolling buffer.
      #
      # @param base64_data [String] JPEG image data
      # @param timestamp [String] ISO timestamp
      # @return [String] path to saved file
      def save(base64_data, timestamp)
        path = frame_path(@index)
        File.binwrite(path, Base64.decode64(base64_data))

        File.write(meta_path(@index), timestamp)

        @index = (@index + 1) % BUFFER_SIZE
        path
      end

      # Path to the most recently saved frame.
      #
      # @return [String, nil]
      def latest
        prev = (@index - 1) % BUFFER_SIZE
        path = frame_path(prev)
        File.exist?(path) ? path : nil
      end

      # Path to a specific frame by index.
      #
      # @param n [Integer] frame number (0-99)
      # @return [String]
      def frame_path(n)
        File.join(DIR, "frame_%03d.jpg" % n)
      end

      # Directory where screenshots are stored.
      #
      # @return [String]
      def dir
        DIR
      end

      private

      def meta_path(n)
        File.join(DIR, "frame_%03d.meta" % n)
      end
    end
  end
end
