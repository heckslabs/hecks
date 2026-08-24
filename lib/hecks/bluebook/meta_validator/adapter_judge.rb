module Hecks
  module Bluebook
    module MetaValidator
      # Offers a built .adapter to the language that describes adapters.
      #
      # A sibling of a bluebook again, the same shape PortJudge already is
      # one level over — its own file, its own door, judged through its
      # own self-hosted language (adapter.bluebook) rather than left as a
      # plain Ruby struct nothing checks. Whole-project table-unification
      # survey, item #13's remaining builders.
      class AdapterJudge
        attr_reader :refusals

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
          offer(label) { @runtime.dispatch(verb, **args(payload)) }
        end

        def judge!
          send_to("Adapter::Adapter.Declare", @adapter.name, name: v(@adapter.name), port: v(@adapter.port))

          Array(@adapter.fields).each do |field|
            send_to("Adapter::Adapter.AddField", @adapter.name, name: @adapter.name, value: v(field))
          end

          Array(@adapter.secrets).each do |secret|
            send_to("Adapter::Adapter.AddSecret", @adapter.name, name: @adapter.name, value: v(secret))
          end
        end
      end
    end
  end
end
