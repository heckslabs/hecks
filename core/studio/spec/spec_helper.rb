# spec/spec_helper.rb
#
# Hecks Studio — server-side spec configuration.
#
# Boots StudioApp (Sinatra::Base in app.rb) under Rack::Test, parses
# rendered pages with Nokogiri, and exposes one helper used by every
# spec:
#
#   render_page("/")  # => Nokogiri::HTML::Document
#
# Constants:
#   DISPATCH_ENDPOINT — POST route the tag-dispatch harness hits.
#                       Matches the route Agent B wires for client_commands.
#
# Usage:
#   require_relative "spec_helper"
#   include Rack::Test::Methods
#   def app; StudioApp; end
#   doc = render_page("/")
#
# This file MUST stay below 200 LOC and load fast — the project rule
# is the whole suite under one second.

$LOAD_PATH.unshift File.expand_path("../../../../hecks/lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../../../hecks/ruby", __dir__)

require "rspec"
require "rack/test"

# Nokogiri and Sinatra are not required for spec discovery to succeed —
# we want `bundle exec rspec` to load all four files even when the app
# itself is mid-construction. Each load failure becomes a clear pending
# message instead of a stack trace.
def safe_require(name)
  require name
  true
rescue LoadError => e
  warn "[studio spec_helper] could not load #{name.inspect}: #{e.message}"
  false
end

NOKOGIRI_AVAILABLE = safe_require("nokogiri")
SINATRA_AVAILABLE  = safe_require("sinatra/base")

APP_PATH = File.expand_path("../app.rb", __dir__)
APP_LOADED =
  if File.exist?(APP_PATH)
    begin
      require APP_PATH
      true
    rescue StandardError, ScriptError => e
      warn "[studio spec_helper] app.rb failed to load: #{e.class}: #{e.message}"
      false
    end
  else
    warn "[studio spec_helper] app.rb not present at #{APP_PATH} (Agent B's slice)"
    false
  end

STUDIO_APP =
  if APP_LOADED && defined?(StudioApp)
    StudioApp
  else
    nil
  end

# Route the tag-dispatch harness POSTs to. The webapp/client_commands
# capability conventionally mounts at /commands ; if Agent B chooses
# a different path, update this constant only.
DISPATCH_ENDPOINT = "/commands".freeze

module StudioSpecHelpers
  # GET +path+ via Rack::Test, return a parsed Nokogiri document.
  # Returns nil if the app isn't loaded or Nokogiri isn't available —
  # callers must check and pend, not assume.
  def render_page(path)
    return nil unless STUDIO_APP && NOKOGIRI_AVAILABLE
    get(path)
    return nil unless last_response.ok?
    Nokogiri::HTML(last_response.body)
  end

  # True iff the studio is bootable: app loaded, Sinatra available,
  # StudioApp defined. Specs use this to pend instead of crash.
  def studio_ready?
    STUDIO_APP && SINATRA_AVAILABLE && NOKOGIRI_AVAILABLE
  end

  # Reason string for pending blocks when the studio isn't ready.
  def studio_pending_reason
    return "Sinatra not loadable" unless SINATRA_AVAILABLE
    return "Nokogiri not loadable" unless NOKOGIRI_AVAILABLE
    return "app.rb not present or failed to load" unless STUDIO_APP
    nil
  end
end

RSpec.configure do |config|
  config.include Rack::Test::Methods
  config.include StudioSpecHelpers
  config.formatter = :progress
  config.order = :defined
end
