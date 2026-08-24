require "json"

module Hecks
  module Adapters
    class Lambda
      # THE THIN AWS CLIENT — shared by this adapter's own read methods
      # (Lambda#find/#all/#count/#query) and Runtime::RemoteDispatcher's
      # write methods. One Lambda invoke, one JSON round trip, nothing
      # domain-specific: neither caller needs to know an AWS SDK is
      # involved at all.
      #
      # FUNCTION NAME IS COMPUTED, NOT PASSED — `"hecks-#{domain}"`,
      # lowercased, matches bin/project_deploy's own `stack_name`
      # exactly (bin/project_deploy: `stack_name = "hecks-#{domain_name}"`,
      # `domain_name = File.basename(domain)`). `domain` here is the
      # bluebook's OWN declared name (`Embryonaut`, not the directory);
      # today's real corpus has directory name == declared name
      # lowercased for every domain that deploys, so `.downcase` alone
      # reproduces the same string bin/project_deploy computes from the
      # directory — this is a real, load-bearing assumption, not a
      # coincidence to lean on silently forever if that ever stops
      # holding.
      class Client
        def initialize(domain:, region:)
          require "aws-sdk-lambda"
          @function_name = "hecks-#{domain.to_s.downcase}"
          @client = Aws::Lambda::Client.new(region: region)
        end

        # THE WHOLE DOMAIN, EVERY TIME — matches dispatch::read's own
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
