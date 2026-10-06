module Hecks
  module Projections
    module Deploy
      # The Makefile lines that read a stack's outputs for the temporary bastion: one `$(eval ...)`
      # per output, and the `--parameter-overrides` the bastion stack is deployed with. Included
      # into a stack object that answers `stack_outputs` and `bastion_parameters`.
      module BastionLines
        # @return [String] one `$(eval VAR := $(shell aws cloudformation describe-stacks ...))` per
        #   output, tab-separated for a Makefile recipe
        def eval_lines
          stack_outputs.map { |output| eval_line(output) }.join("\n\t")
        end

        # @return [String] `Name=$(VAR)` for each bastion parameter, space-separated
        def parameter_overrides
          outputs = stack_outputs
          bastion_parameters.map do |parameter|
            source = outputs.find { |output| output[:key] == parameter[:from_output] }
            "#{parameter[:name]}=$(#{source[:var]})"
          end.join(" ")
        end

        private

        def eval_line(output)
          "$(eval #{output[:var]} := $(shell aws cloudformation describe-stacks --stack-name $(STACK) " \
            "--query \"Stacks[0].Outputs[?OutputKey=='#{output[:key]}'].OutputValue\" --output text))"
        end
      end
    end
  end
end
