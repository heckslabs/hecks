require "net/http"

module Hecks
  module CLI
    class SmokeHttp
      # The HTTP calls a run makes to the service under check, and the status assertions on them.
      module Transport
        private

        def state
          @settings[:state_path] ? get(@settings[:state_path]).body : nil
        end

        def get(path)
          request(Net::HTTP::Get.new(URI.join(@target, path)))
        end

        def post(body, headers)
          req = Net::HTTP::Post.new(URI.join(@target, @settings.fetch(:path)))
          headers.each { |name, value| req[name] = value }
          req["Content-Type"] = "application/json"
          req.body = body
          request(req)
        end

        def request(req)
          options = { use_ssl: req.uri.scheme == "https", read_timeout: 8, open_timeout: 8 }
          Net::HTTP.start(req.uri.host, req.uri.port, **options) { |http| http.request(req) }
        end

        def expect_status(res, code)
          raise Failure, "expected #{code}, got #{res.code}" unless res.code.to_i == code
        end

        def expect_success(res)
          raise Failure, "expected 2xx, got #{res.code}: #{res.body.to_s[0, 200]}" unless res.code.to_i.between?(200, 299)
        end

        def expect_refused(res)
          raise Failure, "expected a 4xx refusal, got #{res.code}" unless res.code.to_i.between?(400, 499)
        end
      end
    end
  end
end
