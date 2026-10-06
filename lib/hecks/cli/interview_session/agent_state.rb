module Hecks
  module CLI
    class InterviewSession
      # What the session tells the agent: the interview so far, what was accepted, and the gaps.
      module AgentState
        private

        def state
          plain = InterviewDraft.from_record(current)
          { task: format(TASK, subject: @subject), subject: @subject, expert: @expert, verbs: VERBS,
            exchanges: plain[:exchanges].each_with_index.map { |e, i| e.slice(:question, :answer).merge(number: i + 1) },
            accepted: accepted_state(plain), gaps: gaps(plain) }
        end

        def accepted_state(plain)
          { things:      InterviewDraft.accepted(plain, :things).map { |f| f.slice(:name, :identifier) },
            actions:     accepted_actions(plain),
            fields:      InterviewDraft.accepted(plain, :fields).map { |f| f.slice(:thing, :name, :values) },
            transitions: InterviewDraft.accepted(plain, :transitions).map { |f| f.slice(:thing, :action, :to, :from) },
            rules:       InterviewDraft.accepted(plain, :rules).map { |f| f.slice(:statement) } }
        end

        def accepted_actions(plain)
          InterviewDraft.accepted(plain, :actions).map { |f| f.slice(:name, :thing, :event, :creates, :takes, :by) }
        end

        # What the interview has not yet pinned down, in words a model can act on.
        def gaps(plain)
          things = InterviewDraft.accepted(plain, :things).map { |t| t[:name].to_s }
          actions = InterviewDraft.accepted(plain, :actions)
          action_gaps(things, actions) + shape_gaps(plain, things, actions)
        end

        def action_gaps(things, actions)
          idle_gaps(things, actions) + uncreated_gaps(things, actions) + unplaced_gaps(things, actions)
        end

        def idle_gaps(things, actions)
          things.reject { |t| actions.any? { |a| a[:thing] == t } }.map { |t| "nothing is yet said to happen to #{t}" }
        end

        def uncreated_gaps(things, actions)
          things.reject { |t| actions.any? { |a| a[:thing] == t && a[:creates] } }.map { |t| "nothing yet creates #{t}" }
        end

        # Actions on a thing nobody accepted.
        def unplaced_gaps(things, actions)
          actions.reject { |a| things.include?(a[:thing].to_s) }.map { |a| "#{a[:name]} names #{a[:thing]}, not yet a thing" }
        end

        # What a thing is not yet said to have, and how it moves from one state to the next.
        def shape_gaps(plain, things, actions)
          bare_gaps(things, InterviewDraft.accepted(plain, :fields)) +
            unmoved_gaps(things, actions, InterviewDraft.accepted(plain, :transitions))
        end

        def bare_gaps(things, fields)
          things.reject { |t| fields.any? { |f| f[:thing] == t } }
                .map { |t| "nothing is yet said #{t} has, beyond its identifier" }
        end

        def unmoved_gaps(things, actions, steps)
          changing = things.select { |t| actions.count { |a| a[:thing] == t && !a[:creates] } > 1 }
          changing.reject { |t| steps.any? { |s| s[:thing] == t } }
                  .map { |t| "nothing yet says how #{t} moves from one state to the next" }
        end
      end
    end
  end
end
