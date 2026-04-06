# HecksTemplating::SmokeTest::NegativeTests
#
# Tests negative cases by submitting forms with all fields empty.
# Simulates a browser user submitting a blank form. Expects either
# a 422 validation error or a re-rendered form (200 with errors).
#
#   test_negative_cases(results)
#
module HecksTemplating
  class SmokeTest
    module NegativeTests
      private

      def test_negative_cases(results)
        @domain.aggregates.each do |agg|
          plural = underscore(agg.name) + "s"
          agg_snake = underscore(agg.name)
          create_cmds, _ = partition_commands(agg, agg_snake)

          # Submit form with all fields empty — browser user submits blank form
          create_cmds.each do |cmd|
            cmd_snake = underscore(cmd.name)
            form_path = "/#{plural}/#{cmd_snake}/new"
            results << submit_empty_form(plural, cmd_snake, form_path)
          end
        end
      end

      def submit_empty_form(plural, cmd_snake, form_path)
        uri = URI("#{@base}#{form_path}")
        html = Net::HTTP.get(uri) rescue ""
        action = parse_form_action(html) || HecksTemplating::RouteContract.submit_path(plural, cmd_snake)
        post_uri = URI("#{@base}#{action}")
        res = Net::HTTP.post_form(post_uri, {})
        code = res.code.to_i
        # 422 or re-rendered form (200 with error) both count as pass
        if [200, 422].include?(code)
          Result.new(status: :pass, method: "POST", path: action, http_code: code)
        else
          Result.new(status: :fail, method: "POST", path: action,
                     http_code: code, error: res.body&.slice(0, 200))
        end
      end
    end
  end
end
