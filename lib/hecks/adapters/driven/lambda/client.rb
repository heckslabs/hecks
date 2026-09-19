require "json"

module Hecks
  module Adapters
    class Lambda
      # The thin AWS client — shared by this adapter's own read methods
      # (Lambda#find/#all/#count/#query) and Runtime::RemoteDispatcher's
      # write methods. One Lambda invoke, one JSON round trip, nothing
      # domain-specific: neither caller needs to know an AWS SDK is
      # involved at all.
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
      # So the name can be named, in the one place the rest of this
      # deployment is already described: the `.world`'s own
      # `persisted_by("Lambda")`/`dispatched_by("Lambda")` block, beside
      # `region`. Given, it wins outright; absent, the computation above
      # is unchanged, which is every domain whose stack name was never
      # pinned.
      class Client
        def initialize(domain:, region:, function: nil)
          require "aws-sdk-lambda"
          @function_name = function.to_s.empty? ? "hecks-#{domain.to_s.downcase}" : function.to_s
          @client = Aws::Lambda::Client.new(region: region)
        end

        # The function this client actually invokes — read by
        # `Runtime::WiringError` messages and worth asserting on
        # directly, since "which function did we call" is precisely the
        # thing that used to be unanswerable from outside.
        attr_reader :function_name

        # The whole domain, every time — matches dispatch::read's own
        # rehydrate-the-full-journal design (Phase 1, rust/host). No
        # caching here, deliberately not even per-request: Lambda#all
        # used to memoize this across calls, which silently served
        # stale reads for a warm web process's whole lifetime once a
        # write happened elsewhere — see Lambda#instances's own comment
        # on the real, live bug that caught it.
        def read
          invoke({ "read" => true })
        end

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
