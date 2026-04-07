# HecksTemplating::SmokeTest::FormSubmission
#
# Browser-style form submission. GETs the form page, parses the HTML
# to extract the action URL and all input fields (including hidden
# ones with pre-filled values), fills sample data, POSTs form-urlencoded,
# and follows the redirect to the show page.
#
module HecksTemplating
  class SmokeTest
    # HecksTemplating::SmokeTest::FormSubmission
    #
    # Browser-style form submission mixin: GETs form pages, parses HTML, fills fields, and POSTs submissions.
    #
    module FormSubmission
      private

      # Submit a form the way a browser would:
      # 1. GET the form page (capturing Set-Cookie for CSRF)
      # 2. Parse action URL and all input fields from HTML
      # 3. Fill empty fields with sample data
      # 4. POST form-urlencoded with CSRF cookie forwarded
      # 5. Expect redirect (3xx) or success (2xx)
      #
      # @param form_path [String] GET path for the form page (e.g., /pizzas/create_pizza/new)
      # @param cmd [Command] the command IR for generating sample values
      # @param label [String] human-readable label for results
      # @param strict [Boolean] if true, 422 is a failure
      # @return [Array<Result>] results for the GET and POST.
      #   The last result's error field contains the redirect ID if available.
      def submit_form(form_path, cmd, label, strict: true, agg_snake: nil)
        results = []

        # 1. GET the form page
        get_result = check_get(form_path, "#{label} form")
        results << get_result
        return results unless get_result.status == :pass

        # 2. Parse the HTML — also capture CSRF cookie from GET response
        uri = URI("#{@base}#{form_path}")
        get_res = Net::HTTP.get_response(uri)
        html = get_res.body
        csrf_cookie = parse_csrf_cookie(get_res)

        plural, cmd_snake = form_path.split("/").drop(1).first(2)
        action = parse_form_action(html) || HecksTemplating::RouteContract.submit_path(plural, cmd_snake)
        fields = parse_form_fields(html)

        # Field count check — catch empty or broken forms
        if agg_snake
          ac = HecksTemplating::AggregateContract
          expected_attrs = ac.user_fields(cmd, agg_snake)
          expected_count = expected_attrs.size + ac.user_refs(cmd, agg_snake).size
          if fields.size < expected_count
            results << Result.new(
              status: :fail,
              method: "GET",
              path: form_path,
              http_code: 200,
              error: "#{label} form has #{fields.size} fields, expected at least #{expected_count} (#{expected_attrs.map(&:name).join(", ")})"
            )
            return results
          end
        end

        # 3. Fill empty fields with sample data from command
        cmd.attributes.each do |attr|
          key = attr.name.to_s
          # Only fill if the field is empty or missing
          if !fields.key?(key) || fields[key].to_s.empty?
            fields[key] = sample_value(attr)
          end
        end

        # 4. POST form-urlencoded, forwarding CSRF cookie if present
        post_uri = URI("#{@base}#{action}")
        res = post_with_cookie(post_uri, fields, csrf_cookie)
        code = res.code.to_i

        # 5. Check result
        if (200..399).include?(code)
          results << Result.new(status: :pass, method: "POST", path: action, http_code: code)
          # Follow redirect to verify show page
          if (300..399).include?(code) && res["Location"]
            show_path = res["Location"]
            # Extract ID from redirect for callers to use
            @last_submitted_id = show_path[/id=([^&]+)/, 1]
            results << check_get(show_path, "#{label} show after submit")
          end
        elsif code == 422 && !strict
          results << Result.new(status: :pass, method: "POST", path: action, http_code: code)
        else
          error = res.body.to_s.slice(0, 200)
          results << Result.new(status: :fail, method: "POST", path: action, http_code: code, error: error)
        end

        results
      rescue => e
        results << Result.new(status: :fail, method: "POST", path: form_path, http_code: 0, error: e.message)
        results
      end

      # Parse <form action="..."> from HTML
      def parse_form_action(html)
        match = html.match(/<form[^>]*action="([^"]*)"/)
        match ? match[1] : nil
      end

      # Parse all <input> fields from HTML, returning { name => value }
      # Captures hidden fields (pre-filled by server), text inputs, etc.
      def parse_form_fields(html)
        fields = {}
        # Match <input ... name="..." value="..." ...>
        html.scan(/<input[^>]*>/).each do |tag|
          name = tag[/name="([^"]*)"/, 1]
          value = tag[/value="([^"]*)"/, 1] || ""
          fields[name] = value if name
        end
        # Match <select ... name="..."> with first <option value="...">
        html.scan(/<select[^>]*name="([^"]*)"[^>]*>.*?<option[^>]*value="([^"]*)"[^>]*>/m).each do |name, value|
          fields[name] = value if name
        end
        fields
      end

      # Extract CSRF token cookie value from a GET response Set-Cookie header.
      def parse_csrf_cookie(response)
        set_cookie = Array(response.get_fields("Set-Cookie") || [])
        set_cookie.each do |cookie|
          if (cookie_match = cookie.match(/\A_csrf_token=([^;]+)/))
            return cookie_match[1]
          end
        end
        nil
      end

      # POST form data with an optional CSRF cookie forwarded in the Cookie header.
      def post_with_cookie(uri, fields, csrf_cookie)
        req = Net::HTTP::Post.new(uri)
        req.set_form_data(fields)
        req["Cookie"] = "_csrf_token=#{csrf_cookie}" if csrf_cookie
        Net::HTTP.start(uri.host, uri.port) { |http| http.request(req) }
      end
    end
  end
end
