module Hecks
  module Bluebook
    module MetaValidator
      # Offers a built .adapter to the self-hosted adapter language (adapter.bluebook).
      class AdapterJudge
        # Marks a field with no declared default; `nil` and `false` are defaults too.
        NONE = Object.new.freeze

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
          send_to("Adapter::Adapter.Declare", @adapter.name, name: v(@adapter.name), port: v(@adapter.port),
                                                             runs: v(@adapter.runs))
          add_fields
          add_all("AddSecret", @adapter.secrets)
          add_all("AnswerQuery", @adapter.answered_queries)
          add_all("Provide", @adapter.capabilities)
        end

        # Offers one `AddField` per field, each with its declared default when it has one.
        def add_fields
          Array(@adapter.fields).each do |field|
            default = @adapter.declared_defaults.fetch(field.to_sym, NONE)
            send_to("Adapter::Adapter.AddField", @adapter.name, name: @adapter.name, value: v(field),
                                                                default: default.equal?(NONE) ? nil : v(default.inspect))
          end
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
