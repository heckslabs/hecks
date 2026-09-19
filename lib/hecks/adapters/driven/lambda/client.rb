require "json"

module Hecks
  module Adapters
    class Lambda
      # **The thin AWS client** — shared by this adapter's own read methods
      # (Lambda#find/#all/#count/#query) and Runtime::RemoteDispatcher's
      # write methods. One Lambda invoke, one JSON round trip, nothing
      # domain-specific: neither caller needs to know an AWS SDK is
      # involved at all.
      #
      # ## How the function name is resolved
      #
      # Computed unless it is named — `"hecks-#{domain}"`,
      # lowercased, matches bin/project_deploy's own `stack_name`
      # exactly (bin/project_deploy: `stack_name = "hecks-#{domain_name}"`,
      # `domain_name = File.basename(domain)`). `domain` here is the
      # bluebook's own declared name (`Embryonaut`, not the directory);
      # today's real corpus has directory name == declared name
      # lowercased for every domain that deploys, so `.downcase` alone
      # reproduces the same string bin/project_deploy computes from the
      # directory.
      #
      # ## When the assumption breaks
      #
      # That assumption is not always true, and when it breaks nothing
      # about it is recoverable from here. `bin/project_deploy` honours
      # a `.world`'s own `stack_prefix`/`stack_name` — settings that
      # exist precisely so a domain whose AWS identity predates a rename
      # keeps targeting the stack that is actually live rather than
      # standing up a second, empty one beside it. A real one:
      # embryonautfoundersapp deploys as `hecksagain-embryonaut`, and no
      # value of `domain` (or of `DOMAIN_NAME`, the deployed-Lambda
      # override callers already pass) can make this computation produce
      # a name with no dash after "hecks". Every Ruby-side read and
      # dispatch for that app has therefore been invoking a function
      # that does not exist — found live, and visible in the deployed
      # journal having never received a single row.
      #
      # ## The fix
      #
      # So the name can be named, in the one place the rest of this
      # deployment is already described: the `.world`'s own
      # `persisted_by("Lambda")`/`dispatched_by("Lambda")` block, beside
      # `region`. Given, it wins outright; absent, the computation above
      # is unchanged, which is every domain whose stack name was never
      # pinned.
      class Client
        # Resolves the target function name and builds the underlying AWS SDK client.
        #
        # @param domain [String, Symbol] the bluebook's own declared domain name, lowercased
        #   into the computed function name when `function` is absent
        # @param region [String] the AWS region to invoke in
        # @param function [String, Symbol, nil] the function name to call, when it is not
        #   `"hecks-#{domain.downcase}"`; nil or empty uses the computed name
        # @raise [LoadError] if the `aws-sdk-lambda` gem is not installed
        def initialize(domain:, region:, function: nil)
          require "aws-sdk-lambda"
          @function_name = function.to_s.empty? ? "hecks-#{domain.to_s.downcase}" : function.to_s
          @client = Aws::Lambda::Client.new(region: region)
        end

        # The function this client actually invokes — read by
        # `Runtime::WiringError` messages and worth asserting on
        # directly, since "which function did we call" is precisely the
        # thing that is otherwise unanswerable from outside.
        #
        # @return [String] the resolved AWS Lambda function name
        attr_reader :function_name

        # Reads the whole remote Store in one invoke.
        #
        # **The whole domain, every time** — matches dispatch::read's own
        # rehydrate-the-full-journal design (Phase 1, rust/host). No
        # caching here, deliberately not even per-request: memoizing this
        # across calls would silently serve stale reads for a warm web
        # process's whole lifetime once a write happened elsewhere — see
        # Lambda#instances's own comment on the real, live bug that
        # caught exactly that.
        #
        # @return [Hash] the invoked function's parsed JSON response, expected to hold an
        #   `"instances"` key
        # @raise [Runtime::WiringError] if the invoke reports a function error
        def read
          invoke({ "read" => true })
        end

        # Dispatches a command to the remote runtime in one invoke.
        #
        # @param verb [String] the fully-qualified command verb to dispatch
        # @param args [Hash] the flat command facts (`Dispatcher#dispatch_flat`'s own wire
        #   form)
        # @param role [String, Symbol, nil] the acting role to send, when the call needs one;
        #   nil omits the `"role"` key from the payload entirely
        # @return [Hash] the invoked function's parsed JSON response, expected to hold
        #   `"refusals"` and `"mutations"` keys
        # @raise [Runtime::WiringError] if the invoke reports a function error
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
