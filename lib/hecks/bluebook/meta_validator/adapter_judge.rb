module Hecks
  module Bluebook
    module MetaValidator
      # Offers a built .adapter to the self-hosted adapter language (adapter.bluebook).
      class AdapterJudge
        attr_reader :refusals

        # @param adapter [Bluebook::Adapter] the built adapter to judge
        def initialize(adapter)
          @adapter  = adapter
          @refusals = []
          @runtime  = MetaValidator.fresh_runtime
          judge!
        end

        private

        def v(text) = text.nil? ? nil : { value: text.to_s }

        def args(pairs) = pairs.compact

        def offer(label)
          yield
        rescue Runtime::GivenNotMet, Runtime::InvariantViolation,
               Runtime::TypeMismatch, Runtime::NotFound => e
          @refusals << "#{label}: #{e.message}"
        rescue Runtime::UnknownVerb
          nil
        end

        def send_to(verb, label, **payload)
          offer(label) { @runtime.dispatch_flat(verb, args(payload)) }
        end

        def judge!
          send_to("Adapter::Adapter.Declare", @adapter.name, name: v(@adapter.name), port: v(@adapter.port))
          add_all("AddField", @adapter.fields)
          add_all("AddSecret", @adapter.secrets)
        end

        # Offers one `verb` per value, each addressed to the adapter by name.
        def add_all(verb, values)
          Array(values).each do |value|
            send_to("Adapter::Adapter.#{verb}", @adapter.name, name: @adapter.name, value: v(value))
          end
        end
      end
    end
  end
end
