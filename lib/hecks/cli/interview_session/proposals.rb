module Hecks
  module CLI
    class InterviewSession
      # Putting an agent's proposed finding to the developer: reading its fields, proposing it to
      # the SME chapter, describing it, and recording the decision.
      module Proposals
        private

        def review(proposal)
          config = KINDS[proposal.verb]
          return say("Ignored a proposal for #{proposal.verb}: not a finding I know.") unless config

          fields = fields_of(proposal, config)
          missing = missing_fields(config, fields)
          return say("Ignored a #{config[:kind]} proposal with no #{missing.join(", ")}.") unless missing.empty?

          put_to_developer(proposal, config, fields)
        end

        def missing_fields(config, fields)
          config[:fields].reject { |f| config[:optional].include?(f) || fields[f].to_s.strip != "" }
        end

        def put_to_developer(proposal, config, fields)
          number = propose(config, fields) or return
          say("  Proposed #{describe(config, fields)}")
          say("  because: #{proposal.rationale}")
          decide(config, number, accept?("  Accept? [Y/n] "))
        end

        def fields_of(proposal, config)
          fields = argument_fields(proposal, config)
          fields.reject { |key, value| key != "creates" && config[:optional].include?(key) && value.to_s.strip.empty? }
        end

        def argument_fields(proposal, config)
          rows = proposal.arguments.to_h { |row| [row[:name].to_s, row[:value]] }
          fields = rows.slice(*config[:fields])
          fields["creates"] = TRUE_WORDS.include?(fields["creates"].to_s.downcase) if fields.key?("creates")
          fields
        end

        def propose(config, fields)
          number = (@number += 1)
          args = fields.transform_keys(&:to_sym).merge(number: number, source: current.exchanges.size)
          current.public_send(config[:propose], **args)
          number
        rescue StandardError => e
          say("  Could not keep that finding: #{reason(e)}")
          nil
        end

        def decide(config, number, accepted)
          verb = accepted ? config[:accept] : config[:reject]
          @runtime.dispatch_flat("SME::Interview.#{config[:entity]}.#{verb}",
                                 reference: { value: @reference }, number: { value: number })
          say(accepted ? "  Accepted." : "  Rejected.")
        rescue StandardError => e
          say("  Could not record the decision: #{reason(e)}")
        end

        def describe(config, fields)
          case config[:kind]
          when "thing" then "thing: #{fields["name"]}, identified by #{fields["identifier"]}"
          when "action" then describe_action(fields)
          when "field" then "field: #{fields["name"]} of #{fields["thing"]}#{", one of #{fields["values"]}" if fields["values"]}"
          when "transition" then describe_transition(fields)
          else "rule: #{fields["statement"]}"
          end
        end

        def describe_action(fields)
          "action: #{fields["name"]} on #{fields["thing"]}, announcing #{fields["event"]}" \
            "#{", creating it" if fields["creates"]}#{action_extras(fields)}"
        end

        def describe_transition(fields)
          "transition: #{fields["action"]} leaves #{fields["thing"]} #{fields["to"]}" \
            "#{", from #{fields["from"]}" if fields["from"]}"
        end

        def action_extras(fields)
          "#{", taking #{fields["takes"]}" if fields["takes"]}#{", by #{fields["by"]}" if fields["by"]}"
        end

        def reason(error) = error.message.sub(/\A[A-Z]\w* refused\s+[—-]\s+/, "").strip
      end
    end
  end
end
