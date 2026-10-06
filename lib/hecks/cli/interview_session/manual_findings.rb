module Hecks
  module CLI
    class InterviewSession
      # The plain prompt: findings typed by the developer, accepted as they are entered.
      module ManualFindings
        private

        def manual_findings
          loop do
            kind = ask("Add a finding from that answer? thing, action, rule, field or transition (enter to skip): ")
            kind = kind.to_s.strip.downcase
            break if kind.empty?

            typed = typed_finding(kind) or next say("  I only know thing, action, rule, field and transition.")
            config = KINDS["SME::Interview.Propose#{kind.capitalize}"]
            number = propose(config, typed) or next
            decide(config, number, true)
          end
        end

        def typed_finding(kind)
          case kind
          when "thing" then named("Name" => "name", "Identified by" => "identifier")
          when "action" then typed_action
          when "rule" then named("The rule, in the expert's words" => "statement")
          when "field" then named({ "On which thing" => "thing", "Name" => "name",
                                    "Values it may take, comma separated (enter for any)" => "values" }, %w[values])
          when "transition" then named({ "On which thing" => "thing", "Caused by which action" => "action",
                                         "Leaves it in the state" => "to",
                                         "From the state (enter if it starts there)" => "from" }, %w[from])
          end
        end

        def typed_action
          fields = named("Name" => "name", "On which thing" => "thing", "It announces (event)" => "event") or return nil
          fields.merge("creates" => TRUE_WORDS.include?(ask("  Does it create the thing? [y/N] ").to_s.strip.downcase))
        end

        def named(prompts, optional = [])
          fields = prompts.to_h { |label, key| [key, ask("  #{label}: ").to_s.strip] }
          return nil unless fields.all? { |key, value| optional.include?(key) || !value.empty? }

          fields.reject { |key, value| optional.include?(key) && value.empty? }
        end
      end
    end
  end
end
