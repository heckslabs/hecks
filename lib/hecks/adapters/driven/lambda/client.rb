require "json"

module Hecks
  module Adapters
    class Lambda
      # The thin AWS client shared by this adapter's read methods and
      # Runtime::RemoteDispatcher's writes: one Lambda invoke, one JSON round trip.
      #
      # The function name defaults to `"hecks-#{domain.downcase}"`, matching
      # `hecks deploy recipe.project`'s `stack_name` computation. A domain whose stack
      # name doesn't follow that pattern must pass `function` explicitly, via
      # a `.world`'s `persisted_by("Lambda")`/`dispatched_by("Lambda")` block.
      class Client
        # @param domain [String, Symbol] the bluebook's own declared domain name; computes
        #   the function name when `function` is not given
        # @param region [String] the AWS region to invoke in
        # @param function [String, Symbol, nil] an explicit Lambda function name, from a
        #   `.world`'s `persisted_by("Lambda")`/`dispatched_by("Lambda")` block; nil computes
        #   `"hecks-#{domain.downcase}"`
        def initialize(domain:, region:, function: nil)
          require "aws-sdk-lambda"
          @function_name = function.to_s.empty? ? "hecks-#{domain.to_s.downcase}" : function.to_s
          @client = Aws::Lambda::Client.new(region: region)
        end

        # The function this client actually invokes; used in `Runtime::WiringError`
        # messages and worth asserting on directly in tests.
        attr_reader :function_name

        # Reads the whole domain's current state and event log from the remote function.
        #
        # No caching here, deliberately: a memoized read would go stale the
        # moment a write happens elsewhere in a long-lived process.
        #
        # @return [Hash{String => Object}] the parsed JSON response; the deployed function's
        #   own top-level keys (`"instances"`, `"events"`, …)
        # @raise [Runtime::WiringError] if the function reports a `functionError` (see
        #   `invoke`)
        def read
          invoke({ "read" => true })
        end

        # Dispatches one command to the remote function and returns its parsed response.
        #
        # @param verb [String] the fully-qualified verb to dispatch
        # @param args [Hash] the command's declared arguments
        # @param role [String, Symbol, nil] the role to dispatch as; omitted from the payload
        #   when nil
        # @return [Hash{String => Object}] the parsed JSON response, including a `"refusals"`
        #   array and a `"mutations"` array
        # @raise [Runtime::WiringError] if the function reports a `functionError` (see
        #   `invoke`)
        def dispatch(verb, args, role: nil)
          payload = { "verb" => verb, "args" => args }
          payload["role"] = role if role
          invoke(payload)
        end

        private

        def invoke(payload)
          response = @client.invoke(function_name: @function_name, payload: JSON.generate(payload))
          body = JSON.parse(response.payload.read)

          if response.function_error
            raise Runtime::WiringError,
                  "Lambda #{@function_name} (#{response.function_error}): #{body['errorMessage'] || body}"
          end

          body
        end
      end
    end
  end
end
