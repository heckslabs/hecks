module Hecks
  module Runtime
    class KernelDispatcher
      # Turns a refused dry-run answer from the kernel into the error the in-process path raises.
      #
      # The kernel's dry-run answer names the refusal's class (`"refusal"`) and, per refusal, the
      # attribute, path and rule it is about. A class among `Runtime::DOMAIN_REFUSALS` is raised as
      # that class with the kernel's message; any other is raised as {KernelDispatcher::Refused}.
      # A `GivenNotMet`'s `detail` is not on the wire, so it is left nil.
      module Refusals
        module_function

        # @param answer [Hash] a dry-run answer with `"ok" => false`
        # @return [StandardError] the error to raise
        def from_dry_run(answer)
          message = answer.fetch("error")
          kind = named_class(answer["refusal"])
          return Refused.new(message) unless kind

          kind.new(message, **about(Array(answer["refusals"]).first || {}))
        end

        # @param name [String, nil] a refusal class name, such as `"NotFound"`
        # @return [Class, nil] the matching domain refusal, or nil when it names none
        def named_class(name)
          DOMAIN_REFUSALS.find { |kind| kind.name.split("::").last == name.to_s }
        end

        # @param entry [Hash] one entry of the answer's `"refusals"`
        # @return [Hash{Symbol => String, nil}] the `attribute:`, `path:` and `rule:` it names
        def about(entry)
          { attribute: entry["attribute"], path: entry["path"], rule: entry["rule"] }
        end
      end
    end
  end
end
