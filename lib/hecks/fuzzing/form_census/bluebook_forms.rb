module Hecks
  module Fuzzing
    module FormCensus
      # The bluebook-level constructs an aggregate takes part in, folded onto its own hash so the
      # per-aggregate forms can read them.
      #
      # Policies and read models live on the bluebook, not the aggregate: an `across` policy is
      # attributed to the aggregate whose event it answers, and a read model to each aggregate it
      # takes a head from.
      module BluebookForms
        module_function

        # @param aggregate [Hash] one aggregate of an exported bluebook
        # @param bluebook_ir [Hash] the exported bluebook it belongs to
        # @return [Hash] the aggregate with `across_policies` and `multi_head_read_models` added
        def onto(aggregate, bluebook_ir)
          aggregate.merge("across_policies"        => across_policies(aggregate, bluebook_ir),
                          "multi_head_read_models" => multi_head_read_models(aggregate, bluebook_ir))
        end

        # Policies with a target domain whose triggering event is qualified by this aggregate.
        def across_policies(aggregate, bluebook_ir)
          (bluebook_ir["policies"] || []).select do |policy|
            !policy["target_domain"].to_s.empty? && policy["on_event"].to_s.split(".", 2).first == aggregate["name"]
          end
        end

        # Read models composing two or more aggregate heads, one of them this aggregate.
        def multi_head_read_models(aggregate, bluebook_ir)
          (bluebook_ir["read_models"] || []).select do |read_model|
            heads = read_model["aggregate_heads"] || []
            heads.size >= 2 && heads.any? { |head| head["aggregate"] == aggregate["name"] }
          end
        end
      end
    end
  end
end
