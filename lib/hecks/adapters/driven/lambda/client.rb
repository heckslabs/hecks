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
      # ## Resolving the function name
      #
      # Function name is computed unless it is named — `"hecks-#{domain}"`,
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
      # ## Naming it explicitly
      #
      # So the name can be named, in the one place the rest of this
      # deployment is already described: the `.world`'s own
      # `persisted_by("Lambda")`/`dispatched_by("Lambda")` block, beside
      # `region`. Given, it wins outright; absent, the computation above
      # is unchanged, which is every domain whose stack name was never
      # pinned.
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

        # The function this client actually invokes — read by
        # `Runtime::WiringError` messages and worth asserting on
        # directly, since "which function did we call" is otherwise
        # unanswerable from outside.
        attr_reader :function_name

        # Reads the whole domain's current state and event log from the remote function.
        #
        # **The whole domain, every time** — matches dispatch::read's own
        # rehydrate-the-full-journal design (Phase 1, rust/host). No
        # caching here, deliberately: memoizing this across calls once
        # silently served stale reads for a warm web process's whole
        # lifetime after a write happened elsewhere — see Lambda#instances's
        # own comment on the real, live bug that caught it.
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
