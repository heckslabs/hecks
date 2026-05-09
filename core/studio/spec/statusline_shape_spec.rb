# spec/statusline_shape_spec.rb
#
# Schema-frozen test for /statusline.
#
# The terminal status bar polls /statusline. Its parser is sensitive to
# the JSON shape returned. This spec freezes that shape so any
# unintended drift fails CI loudly. A *deliberate* shape change
# requires editing this spec — the diff is the audit trail and a
# reminder to update the bar's parser in lockstep.
#
# Asserts :
#   - GET /statusline returns 200
#   - response is JSON
#   - top-level keys are exactly :
#       state, last_wake, last_dream, features, updated_at
#   - features is an Array
#   - each feature item has String "name" and String "status"
#
# Does NOT assert on values — only shape. Cadence count, status
# vocabulary, timestamp content are deliberately out of scope.
#
# Usage:
#   bundle exec rspec spec/statusline_shape_spec.rb

require_relative "spec_helper"
require "json"

EXPECTED_TOP_KEYS = %w[state last_wake last_dream features updated_at].freeze

def app
  STUDIO_APP
end

RSpec.describe "GET /statusline" do
  if !STUDIO_APP
    it "is skipped because StudioApp is not loadable" do
      skip "studio app not loaded ; see spec_helper warnings"
    end
  else
    let(:response) { get "/statusline"; last_response }
    let(:body) do
      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise "expected JSON body, got #{e.message} ; raw: #{response.body[0, 200]}"
    end

    it "returns HTTP 200" do
      expect(response.status).to(
        eq(200),
        "expected 200 from /statusline, got #{response.status} " \
        "(body: #{response.body.to_s[0, 200]})"
      )
    end

    it "returns a JSON object" do
      skip "non-200 response — see prior failure" unless response.status == 200
      expect(body).to be_a(Hash)
    end

    it "has exactly the expected top-level keys" do
      skip "non-200 response — see prior failure" unless response.status == 200
      actual = body.keys.sort
      expect(actual).to(
        eq(EXPECTED_TOP_KEYS.sort),
        "statusline schema drift detected.\n" \
        "  expected keys: #{EXPECTED_TOP_KEYS.sort.inspect}\n" \
        "  actual keys:   #{actual.inspect}\n" \
        "If this change is intentional, update statusline_shape_spec.rb " \
        "AND the terminal bar parser at the same time."
      )
    end

    it "exposes features as an Array" do
      skip "non-200 response — see prior failure" unless response.status == 200
      expect(body["features"]).to(
        be_a(Array),
        "expected features to be an Array, got #{body['features'].class}"
      )
    end

    it "shapes each feature item with String name and String status" do
      skip "non-200 response — see prior failure" unless response.status == 200
      features = body["features"]
      skip "features array is empty — nothing to shape-check" if features.empty?

      features.each_with_index do |item, i|
        expect(item).to(
          be_a(Hash),
          "features[#{i}] should be a Hash, got #{item.class}"
        )
        expect(item["name"]).to(
          be_a(String),
          "features[#{i}]['name'] should be a String, got #{item['name'].inspect}"
        )
        expect(item["status"]).to(
          be_a(String),
          "features[#{i}]['status'] should be a String, got #{item['status'].inspect}"
        )
      end
    end
  end
end
