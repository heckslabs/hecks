# HecksTemplating::SmokeTest::EventChecks
#
# Validates the event log after command execution. Fetches /_events
# and checks that expected event names appear. Works identically
# against Ruby and Go servers (same JSON shape).
#
#   check_events(["CreatedPizza", "PlacedOrder"])
#
module HecksTemplating
  class SmokeTest
    # HecksTemplating::SmokeTest::EventChecks
    #
    # Mixin that fetches /_events and validates that expected event names appear in the log.
    #
    module EventChecks
      private

      def fetch_events
        uri = URI("#{@base}/_events")
        res = Net::HTTP.get_response(uri)
        return [] unless res.code.to_i == 200
        parsed = JSON.parse(res.body) rescue nil
        parsed.is_a?(Array) ? parsed : []
      end

      def check_events_contain(expected_names, label)
        events = fetch_events
        event_names = events.map { |e| e["name"] }
        missing = expected_names - event_names
        if missing.empty?
          Result.new(status: :pass, method: "GET", path: "/_events", http_code: 200)
        else
          Result.new(status: :fail, method: "GET", path: "/_events", http_code: 200,
                     error: "#{label}: missing events #{missing.join(', ')}")
        end
      end
    end
  end
end
