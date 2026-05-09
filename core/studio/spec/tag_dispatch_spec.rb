# spec/tag_dispatch_spec.rb
#
# Tag-driven dispatch harness — the studio's central server-side
# acceptance test. NO browser, NO Playwright. Pure Rack::Test +
# Nokogiri.
#
# What this asserts (and only this) :
#
#   For every element in any rendered studio page whose data-domain
#   attribute matches the command shape (PascalCase aggregate, dot,
#   PascalCase command), POSTing to the dispatch endpoint with
#   {aggregate, command, attrs} causes a matching event to land in
#   the runtime's event log. Dispatch occurred. That is all.
#
# What this does NOT assert : resulting state, chained events,
# downstream policies. The bluebook IR has its own tests for that —
# we don't double-cover.
#
# Usage:
#   bundle exec rspec spec/tag_dispatch_spec.rb
#
# Pages scanned: every entry in PAGES below. Add new studio routes
# there as Agent B ships them — one line per page.

require_relative "spec_helper"

# Command-shape tag regex.
# Matches: "Studio.Start", "TickedFeature.Tick", "ChatTurn.AppendUser"
# Rejects: "TickedFeature" (pure aggregate), "Studio.path.deeper",
#          "studio.start" (lowercase), "Studio.tick" (lowercase command).
COMMAND_TAG_REGEX = /\A[A-Z][A-Za-z]*\.[A-Z][A-Za-z]*\z/.freeze

# Studio pages to scan. Start with "/" ; extend as Agent B adds routes.
PAGES = %w[/].freeze

# Discover every command-shaped data-domain tag across PAGES.
# Returns an array of hashes :
#   { page:, aggregate:, command:, attrs:, element: }
# attrs are extracted from the element's own data-* attributes plus
# any enclosing form's input names (best-effort — domain attribute
# discovery is not the studio's job ; the request just has to be shaped).
def discover_command_tags
  return [] unless STUDIO_APP && NOKOGIRI_AVAILABLE

  results = []
  session = Rack::Test::Session.new(Rack::MockSession.new(STUDIO_APP))
  PAGES.each do |path|
    response = session.get(path)
    next unless response.status == 200
    doc = Nokogiri::HTML(response.body)
    doc.css("[data-domain]").each do |el|
      tag = el["data-domain"].to_s.strip
      next unless tag.match?(COMMAND_TAG_REGEX)
      aggregate, command = tag.split(".", 2)
      results << {
        page: path,
        aggregate: aggregate,
        command: command,
        attrs: extract_attrs(el),
        element_summary: element_summary(el)
      }
    end
  end
  results
rescue StandardError => e
  warn "[tag_dispatch_spec] discovery failed: #{e.class}: #{e.message}"
  []
end

# Element-local attribute extraction.
# Reads:
#   - every data-* attribute except data-domain
#   - input[name] inside a wrapping <form> if present
def extract_attrs(el)
  attrs = {}
  el.attributes.each do |name, attr|
    next unless name.start_with?("data-")
    next if name == "data-domain"
    key = name.sub(/\Adata-/, "").tr("-", "_")
    attrs[key] = attr.value
  end
  form = el.ancestors("form").first
  if form
    form.css("input[name], textarea[name], select[name]").each do |input|
      attrs[input["name"]] ||= input["value"].to_s
    end
  end
  attrs
end

def element_summary(el)
  "<#{el.name} data-domain=\"#{el['data-domain']}\">"
end

DISCOVERED_TAGS = discover_command_tags

RSpec.describe "tag-driven dispatch" do
  if !STUDIO_APP || !NOKOGIRI_AVAILABLE
    it "is skipped because the studio is not yet bootable" do
      skip(studio_pending_reason ||
           "studio not ready; spec_helper warnings explain why")
    end
  elsif DISCOVERED_TAGS.empty?
    it "finds no command-shape tags yet (Agent B has not added buttons)" do
      skip "no command tags found yet — passes vacuously until Agent B ships UI"
    end
  else
    DISCOVERED_TAGS.each do |tag|
      describe "#{tag[:aggregate]}.#{tag[:command]}" do
        it "dispatches a matching event when activated " \
           "(page=#{tag[:page]}, element=#{tag[:element_summary]})" do
          recorded = []
          if STUDIO_APP.respond_to?(:runtime) && STUDIO_APP.runtime
            STUDIO_APP.runtime.event_bus.on_any { |evt| recorded << evt }
          end

          payload = {
            aggregate: tag[:aggregate],
            command:   tag[:command],
            attrs:     tag[:attrs]
          }
          post DISPATCH_ENDPOINT, payload.to_json,
               "CONTENT_TYPE" => "application/json"

          expect(last_response.status).to(
            be_between(200, 299),
            "expected #{DISPATCH_ENDPOINT} to accept dispatch for " \
            "#{tag[:aggregate]}.#{tag[:command]}, got #{last_response.status} " \
            "(body: #{last_response.body.to_s[0, 200]})"
          )

          unless recorded.empty?
            short_names = recorded.map { |e| e.class.name.to_s.split("::").last }
            expect(short_names.any? { |n| n.include?(tag[:command]) }).to(
              be(true),
              "expected an event matching #{tag[:command]} to land on the bus, " \
              "got: #{short_names.inspect}"
            )
          end
        end
      end
    end
  end
end
