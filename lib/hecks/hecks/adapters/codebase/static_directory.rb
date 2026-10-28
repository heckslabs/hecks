module Hecks
  module Adapters
    module Codebase
      # A Rack app that serves the files under one directory and nothing outside it.
      #
      # A request for `/about` is answered by `about`, `about.html` or `about/index.html`, in that
      # order, the way a static host with clean URLs answers it; `/` is answered by `index.html`.
      class StaticDirectory
        # @param root [String] the directory to serve
        # @raise [ConsoleCapture::Failure] when the `rack` gem is not installed
        def initialize(root)
          self.class.load_rack
          @root = File.realpath(root)
          @files = Rack::Files.new(@root)
        end

        # @param env [Hash] the Rack environment
        # @return [Array] the Rack response
        def call(env)
          return not_allowed unless %w[GET HEAD].include?(env["REQUEST_METHOD"])

          found = resolve(Rack::Utils.unescape_path(env["PATH_INFO"].to_s))
          return not_found unless found

          @files.call(env.merge("PATH_INFO" => "/#{found}"))
        end

        # Loads Rack when a preview is asked for, so a checkout without the gem still boots.
        #
        # @return [void]
        # @raise [ConsoleCapture::Failure] naming the gem and how to add it
        def self.load_rack
          require "rack"
        rescue LoadError
          raise ConsoleCapture::Failure, "preview needs the rack gem: add `gem \"rack\"` to the Gemfile and bundle"
        end

        private

        # @param path [String] the request path
        # @return [String, nil] the file under the root, relative to it, or nil
        def resolve(path)
          relative = path.delete_prefix("/")
          candidates = [relative, "#{relative}.html", File.join(relative, "index.html").delete_prefix("/")]
          candidates.find { |candidate| inside?(candidate) }
        end

        def inside?(candidate)
          full = File.expand_path(candidate, @root)
          File.file?(full) && File.realpath(full).start_with?("#{@root}/")
        end

        def not_found = [404, { "content-type" => "text/plain" }, ["not found\n"]]

        def not_allowed = [405, { "content-type" => "text/plain", "allow" => "GET, HEAD" }, ["GET and HEAD only\n"]]
      end
    end
  end
end
