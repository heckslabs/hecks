# Hecks::Capabilities::StaticAssets::Port
#
# Runtime-facing static assets port. Resolves file paths, reads
# file content, and maps extensions to MIME types. Transport-
# agnostic — no HTTP specifics leak into this layer.
#
#   port = StaticAssets::Port.new(
#     views_dir: "/app/views",
#     assets_dir: "/app/assets",
#     listen_port: 4567
#   )
#   port.serve_layout           # => "<html>..."
#   port.serve_asset("app.css") # => { content: "...", content_type: "text/css" }
#

module Hecks
  module Capabilities
    module StaticAssets
      # Hecks::Capabilities::StaticAssets::Port
      #
      # Transport-agnostic port for serving static files and layouts.
      #
      class Port
        attr_reader :views_dir, :assets_dir, :listen_port

        MIME_TYPES = {
          ".html" => "text/html",
          ".css"  => "text/css",
          ".js"   => "application/javascript",
          ".json" => "application/json",
          ".png"  => "image/png",
          ".jpg"  => "image/jpeg",
          ".jpeg" => "image/jpeg",
          ".gif"  => "image/gif",
          ".svg"  => "image/svg+xml",
          ".ico"  => "image/x-icon",
          ".woff" => "font/woff",
          ".woff2" => "font/woff2",
          ".ttf"  => "font/ttf",
          ".eot"  => "application/vnd.ms-fontobject",
          ".map"  => "application/json",
          ".txt"  => "text/plain"
        }.freeze

        def initialize(views_dir:, assets_dir:, listen_port:)
          @views_dir = views_dir
          @assets_dir = assets_dir
          @listen_port = listen_port
        end

        # Return the contents of layout.html from the views directory.
        #
        # @return [String, nil] file contents or nil if not found
        def serve_layout
          path = File.join(@views_dir, "layout.html")
          read_file(path)
        end

        # Return the content and content type for a static asset.
        #
        # @param relative_path [String] path relative to assets dir (e.g. "css/app.css")
        # @return [Hash, nil] { content:, content_type: } or nil if not found
        def serve_asset(relative_path)
          safe_path = sanitize_path(relative_path)
          return nil unless safe_path

          full_path = File.join(@assets_dir, safe_path)
          content = read_file(full_path)
          return nil unless content

          { content: content, content_type: content_type(full_path) }
        end

        # Map a file path's extension to its MIME type.
        #
        # @param path [String] file path
        # @return [String] MIME type string
        def content_type(path)
          ext = File.extname(path).downcase
          MIME_TYPES.fetch(ext, "application/octet-stream")
        end

        private

        def read_file(path)
          return nil unless File.exist?(path)

          binary?(path) ? File.binread(path) : File.read(path)
        end

        def binary?(path)
          ext = File.extname(path).downcase
          %w[.png .jpg .jpeg .gif .ico .woff .woff2 .ttf .eot].include?(ext)
        end

        # Prevent directory traversal attacks.
        #
        # @param path [String] untrusted relative path
        # @return [String, nil] sanitized path or nil if unsafe
        def sanitize_path(path)
          clean = path.gsub("\\", "/")
          return nil if clean.include?("..") || clean.start_with?("/")

          clean
        end
      end
    end
  end
end
