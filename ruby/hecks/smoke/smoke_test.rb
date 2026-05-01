# = HecksTemplating::SmokeTest
#
# Browser-style HTTP smoke test for the web explorer. Exercises every
# page like a real user: navigates to forms, fills fields, submits,
# follows redirects, verifies show pages. Validates the event log
# via /_events. Works with both Ruby and Go targets.
#
#   smoke = HecksTemplating::SmokeTest.new("http://localhost:9292", domain)
#   results = smoke.run
#   results.select { |r| r[:status] == :fail }
#
require "net/http"
require "uri"
require "json"
require "hecks/chapters/templating/smoke_test_children"
Hecks::Chapters.load_aggregates(
  Hecks::Templating::SmokeTestChildren,
  base_dir: File.expand_path("smoke_test", __dir__)
)

module HecksTemplating
  # HecksTemplating::SmokeTest
  #
  # Browser-style HTTP smoke test: exercises every web explorer page, submits forms, and validates the event log.
  #
  class SmokeTest
    include EventChecks
    include BehaviorTests
    include FormSubmission

    # HecksTemplating::SmokeTest::Result
    #
    # Value object representing the pass/fail outcome of a single smoke test HTTP request.
    #
    Result = Struct.new(:status, :method, :path, :http_code, :error, keyword_init: true)

    def initialize(base_url, domain)
      @base = base_url.chomp("/")
      @domain = domain
    end

    def run
      reset_server
      results = []
      results << check_get("/", "home")
      results << check_get("/config", "config")
      results << check_get("/_events", "event log")

      @domain.aggregates.each do |agg|
        plural = underscore(agg.name) + "s"
        agg_snake = underscore(agg.name)
        create_cmds, update_cmds = partition_commands(agg, agg_snake)

        results << check_get("/#{plural}", "#{agg.name} index")

        # Create commands — submit via browser form
        expected_events = []
        create_cmds.each do |cmd|
          cmd_snake = underscore(cmd.name)
          form_path = "/#{plural}/#{cmd_snake}/new"
          results.concat(submit_form(form_path, cmd, cmd.name, strict: true, agg_snake: agg_snake))
          expected_events << cmd.inferred_event_name
        end

        # Verify events from create commands
        results << check_events_contain(expected_events, "#{agg.name} create events") unless expected_events.empty?

        # Update commands — navigate to form with ID, submit
        id = fetch_first_id(plural)
        if id
          results << check_get("/#{plural}/show?id=#{id}", "#{agg.name} show")
          # Test update command forms — use non-strict since lifecycle
          # state constraints may prevent some from succeeding (those
          # are tested properly in test_lifecycles)
          update_cmds.each do |cmd|
            cmd_snake = underscore(cmd.name)
            form_path = "/#{plural}/#{cmd_snake}/new?id=#{id}"
            results.concat(submit_form(form_path, cmd, cmd.name, strict: false, agg_snake: agg_snake))
          end
        end
      end

      # Domain behavior tests
      test_queries(results)
      test_scopes(results)
      test_specifications(results)
      test_policies(results)
      test_lifecycles(results)
      test_views(results)
      test_workflows(results)
      test_services(results)
      test_negative_cases(results)

      print_results(results)
      reset_server
      results
    end

    private

    def partition_commands(agg, _agg_snake)
      HecksTemplating::AggregateContract.partition_commands(agg)
    end

    def build_form_data(cmd)
      cmd.attributes.each_with_object({}) do |a, h|
        h[a.name.to_s] = sample_value(a)
      end
    end

    def sample_value(attr)
      case attr.type.to_s
      when /Integer/ then "1"
      when /Float/   then "1.5"
      when /Date/    then "2026-01-01"
      when /Boolean/ then "true"
      else "test_#{attr.name}"
      end
    end

    def fetch_first_id(plural)
      uri = URI("#{@base}/#{plural}")
      req = Net::HTTP::Get.new(uri)
      req["Accept"] = "application/json"
      res = Net::HTTP.start(uri.host, uri.port) { |http| http.request(req) }
      items = JSON.parse(res.body) rescue nil
      items&.first&.dig("id")
    rescue => e
      nil
    end

    def check_get(path, label)
      uri = URI("#{@base}#{path}")
      res = Net::HTTP.get_response(uri)
      body = res.body.to_s
      if res.code.to_i == 200 && !body.include?("Render error")
        Result.new(status: :pass, method: "GET", path: path, http_code: res.code.to_i)
      else
        error = body[/Render error[^<]*/] || "HTTP #{res.code}"
        Result.new(status: :fail, method: "GET", path: path, http_code: res.code.to_i, error: error)
      end
    rescue => e
      Result.new(status: :fail, method: "GET", path: path, http_code: 0, error: e.message)
    end

    # GET a page and verify its body contains the expected text.
    # Used to verify state changes are reflected in the UI.
    def check_show_contains(path, expected_text, label)
      uri = URI("#{@base}#{path}")
      res = Net::HTTP.get_response(uri)
      body = res.body.to_s
      if res.code.to_i == 200 && body.include?(expected_text)
        Result.new(status: :pass, method: "GET", path: path, http_code: 200)
      elsif res.code.to_i != 200
        Result.new(status: :fail, method: "GET", path: path, http_code: res.code.to_i,
                   error: "#{label}: HTTP #{res.code}")
      else
        Result.new(status: :fail, method: "GET", path: path, http_code: 200,
                   error: "#{label}: '#{expected_text}' not found on page")
      end
    rescue => e
      Result.new(status: :fail, method: "GET", path: path, http_code: 0, error: e.message)
    end

    def reset_server
      Net::HTTP.post_form(URI("#{@base}/_reset"), {})
    rescue
      # Server may not support reset — that's OK
    end

    def check_post(path, data, label)
      do_post(path, data, label, allow_422: true)
    end

    def check_post_strict(path, data, label)
      do_post(path, data, label, allow_422: false)
    end

    def do_post(path, data, label, allow_422: true)
      uri = URI("#{@base}#{path}")
      res = Net::HTTP.post_form(uri, data)
      code = res.code.to_i
      pass_range = allow_422 ? (200..422) : (200..399)
      if pass_range.include?(code)
        Result.new(status: :pass, method: "POST", path: path, http_code: code)
      else
        Result.new(status: :fail, method: "POST", path: path, http_code: code, error: res.body&.slice(0, 200))
      end
    rescue => e
      Result.new(status: :fail, method: "POST", path: path, http_code: 0, error: e.message)
    end

    def print_results(results)
      pass = results.count { |r| r.status == :pass }
      fail_count = results.count { |r| r.status == :fail }
      results.each do |r|
        icon = r.status == :pass ? "OK  " : "FAIL"
        line = "#{icon} #{r.method.ljust(4)} #{r.path}"
        line += " -- #{r.error}" if r.error
        puts line
      end
      puts "\n#{pass} passed, #{fail_count} failed (#{results.size} total)"
    end

    def underscore(str)
      Hecks::Utils.underscore(str)
    end
  end
end
