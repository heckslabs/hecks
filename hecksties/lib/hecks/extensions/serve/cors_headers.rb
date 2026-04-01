# Hecks::HTTP::CorsHeaders
#
# Mixin that provides ENV-driven CORS origin logic for Hecks HTTP servers.
# Instead of unconditionally emitting `Access-Control-Allow-Origin: *`,
# servers include this module and call `apply_cors_origin(res)` to set the
# header only when an origin is explicitly configured via environment variable.
#
# ENV variables (checked in order):
#   HECKS_ALLOW_ALL_ORIGINS=true          → emits `*`
#   HECKS_CORS_ORIGIN=https://app.example.com → emits that value
#   (neither set)                          → header is not emitted
#
# Usage:
#   class MyServer
#     include Hecks::HTTP::CorsHeaders
#
#     def handle(req, res)
#       apply_cors_origin(res)
#       # ... rest of handler
#     end
#   end

module Hecks
  module HTTP
    module CorsHeaders
      # Return the CORS origin value based on ENV configuration.
      #
      # Checks HECKS_ALLOW_ALL_ORIGINS first; if truthy returns "*".
      # Otherwise returns HECKS_CORS_ORIGIN if set, or nil if neither is set.
      #
      # @return [String, nil] the origin value to use, or nil to suppress the header
      def cors_origin_value
        return "*" if ENV["HECKS_ALLOW_ALL_ORIGINS"].to_s.downcase == "true"

        origin = ENV["HECKS_CORS_ORIGIN"]
        return origin if origin && !origin.empty?

        nil
      end

      # Set the Access-Control-Allow-Origin header on a response, if configured.
      #
      # Calls {#cors_origin_value}; if non-nil, sets the header. If nil,
      # the header is left unset and no cross-origin access is permitted.
      #
      # @param res [WEBrick::HTTPResponse] the response to modify
      # @return [void]
      def apply_cors_origin(res)
        value = cors_origin_value
        res["Access-Control-Allow-Origin"] = value if value
      end
    end
  end
end
