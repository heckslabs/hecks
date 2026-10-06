require "json"
require "net/http"
require "uri"

require_relative "../../../runtime/errors"

module Hecks
  module Adapters
    class D1
      # HTTP transport exposing the slice of `SQLite3::Database` the shared SQLite code uses.
      class Connection
        ENDPOINT = "https://api.cloudflare.com/client/v4".freeze

        def initialize(account_id:, database_id:, api_token:)
          @uri = URI("#{ENDPOINT}/accounts/#{account_id}/d1/database/#{database_id}/query")
          @api_token = api_token
        end

        def execute(sql, binds = [])
          response_results({ sql: sql, params: binds }).first.fetch("results", [])
        end

        # D1 batches are transactions: statements run in order and a failure rolls all back.
        def batch(statements)
          payload = {
            batch: statements.map do |sql, binds|
              { sql: sql, params: binds || [] }
            end
          }
          response_results(payload).map { |result| result.fetch("results", []) }
        end

        def get_first_row(sql, binds = [])
          execute(sql, binds).first
        end

        def get_first_value(sql, binds = [])
          get_first_row(sql, binds)&.values&.first
        end

        private

        def response_results(payload)
          response = post(payload)
          body = parse_d1_body(response)
          messages = (body["errors"] || []).map { |error| error["message"] }.join("; ")

          raise Runtime::WiringError, "D1 query failed: #{messages.empty? ? response.body : messages}" unless body["success"]

          refuse_failed_statement(body.fetch("result"), messages)
        end

        def post(payload)
          request = Net::HTTP::Post.new(@uri)
          request["Authorization"] = "Bearer #{@api_token}"
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(payload)

          Net::HTTP.start(@uri.host, @uri.port, use_ssl: true) { |http| http.request(request) }
        end

        def refuse_failed_statement(results, messages)
          failed = results.find { |result| result["success"] == false }
          raise Runtime::WiringError, "D1 query failed: #{failed_statement_detail(failed, messages)}" if failed

          results
        end

        def parse_d1_body(response)
          JSON.parse(response.body)
        rescue JSON::ParserError
          raise Runtime::WiringError, "D1 query failed: non-JSON response (HTTP #{response.code}): #{response.body}"
        end

        # Prefers the statement's own error/message (by key presence) over the whole-response one.
        def failed_statement_detail(failed, messages)
          detail =
            if failed.key?("error")
              failed["error"]
            elsif failed.key?("message")
              failed["message"]
            else
              messages
            end
          detail.to_s.empty? ? "a batched statement failed" : detail
        end
      end
    end
  end
end
