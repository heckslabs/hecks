module Hecks
  module Bluebook
    module MetaValidator
      # Offers a built .port to the self-hosted port language (port.bluebook).
      # Refusals are collected in `refusals`.
      class PortJudge
        attr_reader :refusals

        # @param port [Bluebook::Port] the built port to judge
        def initialize(port)
          @port     = port
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
          send_to("Port::Port.Declare", @port.name, name: v(@port.name),
                  verb: v(@port.verb), signal: v(@port.signal))

          Array(@port.answers).each do |answer|
            send_to("Port::Port.AddAnswer", @port.name, name: @port.name, value: v(answer))
          end
        end
      end
    end
  end
end
