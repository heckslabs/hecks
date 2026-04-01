# = ServerHelpers
#
# Shared helpers for specs that boot real HTTP servers as subprocesses.
# Provides port allocation, server readiness polling, and browser-style
# form submission.
#
# Usage:
#   require_relative "support/server_helpers"
#   port = free_port
#   wait_for_server("http://localhost:#{port}/up")
#   submit_form("http://localhost:#{port}", "/some/form/new", "field" => "value")

require "net/http"
require "uri"
require "socket"

def free_port
  s = TCPServer.new(0)
  port = s.addr[1]
  s.close
  port
end

def wait_for_server(url, timeout: 20)
  deadline = Time.now + timeout
  uri = URI(url)
  loop do
    Net::HTTP.get_response(uri)
    return true
  rescue Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError, Net::ReadTimeout
    raise "Server at #{url} did not start in #{timeout}s" if Time.now > deadline
    sleep 0.5
  end
end

# Browser-style form submission: GET the form page, parse the action URL,
# POST form-urlencoded data. Handles route differences between Ruby (/submit)
# and Go (direct POST) transparently.
def submit_form(base_url, form_path, params)
  html = Net::HTTP.get(URI("#{base_url}#{form_path}"))
  action = html.match(/<form[^>]*action="([^"]*)"/)&.captures&.first
  raise "No form action found at #{form_path} on #{base_url}" unless action
  Net::HTTP.post_form(URI("#{base_url}#{action}"), params)
end
