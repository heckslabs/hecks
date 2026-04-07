# __DOMAIN_MODULE__::Server
#
# WEBrick-based HTTP server with JSON API. Routes are generated
# statically from the domain definition — one POST per command,
# GET for list/find per aggregate, plus OpenAPI discovery.

require "json"

module __DOMAIN_MODULE__
  module Server
    class App
      def initialize(domain_module)
        @domain_module = domain_module
      end

      def start(port: 9292)
        unless defined?(WEBrick)
          # Find webrick gem directly — needed for Ruby 3.3+ where bundled_gems blocks require
          Gem.path.each do |gem_path|
            Dir.glob(File.join(gem_path, "gems", "webrick-*", "lib")).each do |lib|
              $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
            end
          end
          require "webrick"
        end
        server = WEBrick::HTTPServer.new(
          Port: port,
          Logger: WEBrick::Log.new($stdout, WEBrick::Log::INFO),
          AccessLog: [[File.open(File::NULL, "w"), WEBrick::AccessLog::COMMON_LOG_FORMAT]]
        )

        mount_routes(server)
        start_watcher(server) if ENV["DOMAIN_LIVE"] != "0"

        trap("INT") { server.shutdown }
        trap("TERM") { server.shutdown }
        $stdout.puts "Serving #{@domain_module.name} on http://localhost:#{port}"
        $stdout.puts "  Live reload: watching lib/ for changes"
        server.start
      end

      private

      def mount_routes(server)
        # Subclasses override this to mount domain-specific routes
      end

      def start_watcher(server)
        lib_dir = File.expand_path("../../lib", server.config[:DocumentRoot] || __dir__)
        # Fall back to finding lib/ relative to this file
        lib_dir = File.expand_path("../..", __dir__) unless Dir.exist?(lib_dir)
        return unless Dir.exist?(lib_dir)

        @file_mtimes = {}
        Dir.glob(File.join(lib_dir, "**/*.rb")).each do |f|
          @file_mtimes[f] = File.mtime(f)
        end

        Thread.new do
          loop do
            sleep 1
            changed = false
            Dir.glob(File.join(lib_dir, "**/*.rb")).each do |f|
              mtime = File.mtime(f)
              if @file_mtimes[f] != mtime
                @file_mtimes[f] = mtime
                begin
                  load f
                  short = f.sub(lib_dir + "/", "")
                  $stdout.puts "  [reload] #{short}"
                  changed = true
                rescue => e
                  $stdout.puts "  [reload error] #{f}: #{e.message}"
                end
              end
            end
          end
        end
      end

      def json_response(res, data, status: 200)
        res.status = status
        res["Content-Type"] = "application/json"
        res.body = JSON.generate(data)
      end

      def json_error(res, error, status: 422)
        res.status = status
        res["Content-Type"] = "application/json"
        body = error.respond_to?(:as_json) ? error.as_json : { error: error.message }
        res.body = JSON.generate(body)
      end

      def parse_body(req)
        return {} if req.body.nil? || req.body.empty?
        JSON.parse(req.body, symbolize_names: true)
      rescue JSON::ParserError
        {}
      end

      def aggregate_to_hash(obj)
        h = { id: obj.id }
        if obj.class.respond_to?(:domain_attributes)
          obj.class.domain_attributes.each do |attr|
            val = obj.send(attr[:name])
            h[attr[:name]] = val.is_a?(Array) ? val.map { |v| v.respond_to?(:id) ? aggregate_to_hash(v) : v } : val
          end
        end
        h[:created_at] = obj.created_at&.iso8601 if obj.respond_to?(:created_at)
        h[:updated_at] = obj.updated_at&.iso8601 if obj.respond_to?(:updated_at)
        h
      end
    end
  end
end
