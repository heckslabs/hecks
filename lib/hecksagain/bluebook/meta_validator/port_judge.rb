module Hecksagain
  module Bluebook
    module MetaValidator
      # Offers a built .port to the language that describes ports.
      #
      # A port is a SIBLING of a bluebook, the same shape WorldJudge already
      # is one level over — its own file, its own door, judged through its
      # own self-hosted language (port.bluebook) rather than left as a plain
      # Ruby struct nothing checks. Whole-project table-unification survey,
      # item #13's remaining builders.
      class PortJudge
        attr_reader :refusals

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
          offer(label) { @runtime.dispatch(verb, **args(payload)) }
        end

        def judge!
          send_to("Port::Port.Declare", @port.name, name: v(@port.name),
                  verb: v(@port.verb), signal: v(@port.signal))
        end
      end
    end
  end
end
