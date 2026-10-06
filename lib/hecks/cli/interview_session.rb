require_relative "interview_draft"

module Hecks
  module CLI
    # One interview, held at a terminal (ADR 0088).
    #
    # hecks drives: it asks the agent for a question, shows it, reads the answer the developer typed
    # back from the expert, records it, asks the agent what the answer names as findings, and puts
    # each to the developer to accept or reject. The agent never dispatches anything. Every SME
    # command is dispatched here, so the domain's own rules are the guard on the interview.
    #
    # With no agent (`--no-ai`), or for a turn the agent could not answer, a plain prompt stands in:
    # a fixed question, and findings typed by the developer.
    class InterviewSession
      NOTICE = "Your answers are sent to a model through your own `claude` login. " \
               "Run with --no-ai to leave it out.".freeze

      FALLBACK_QUESTIONS = [
        "What is the main thing this business keeps track of?",
        "What happens to it, from the beginning to the end?",
        "What must never happen?",
        "Is there anything else I should know?"
      ].freeze

      TASK = "You interview a subject matter expert, through the developer who sits beside them, about the " \
             "business domain called %<subject>s, so the developer can model it. Ask one plain-language " \
             "question at a time about what the business keeps track of, what each thing has, what happens to " \
             "it and who does it, how it moves from one state to the next, and what must never happen. Use the " \
             "expert's own words. Do not assume what kind of business it is, or an " \
             "industry, from the name of the domain: learn it from what the expert says. When you interpret " \
             "an answer, propose findings only with the verbs listed under `verbs`, using the argument " \
             "names given there, and nothing else.".freeze

      VERBS = {
        "SME::Interview.ProposeThing"      => {
          "meaning"   => "a thing the business keeps track of, and the field that identifies one of it",
          "arguments" => %w[name identifier]
        },
        "SME::Interview.ProposeAction"     => {
          "meaning"   => "something that happens to a thing, and the event it announces, in the past tense; " \
                         "creates is true for the action that brings the thing into being; takes lists, comma " \
                         "separated, the fields it needs to be told; by says who does it",
          "arguments" => %w[name thing event creates takes by]
        },
        "SME::Interview.ProposeField"      => {
          "meaning"   => "something a thing has; values lists, comma separated, what it may be when the " \
                         "expert gave a closed set, and is left out for free text",
          "arguments" => %w[thing name values]
        },
        "SME::Interview.ProposeTransition" => {
          "meaning"   => "the state an action leaves a thing in, and the state it had to be in before; the " \
                         "action that creates the thing has no from",
          "arguments" => %w[thing action to from]
        },
        "SME::Interview.ProposeRule"       => {
          "meaning"   => "a rule the expert stated, in their own words",
          "arguments" => %w[statement]
        }
      }.freeze

      # What each finding verb needs, the fields it may leave out, and the SME commands that
      # carry it out and decide it.
      KINDS = {
        "SME::Interview.ProposeThing"      => { kind: "thing", fields: %w[name identifier], optional: [],
                                           propose: :propose_thing!, entity: "ThingFinding",
                                           accept: "AcceptThing", reject: "RejectThing" },
        "SME::Interview.ProposeAction"     => { kind: "action", fields: %w[name thing event creates takes by],
                                            optional: %w[creates takes by], propose: :propose_action!,
                                            entity: "ActionFinding", accept: "AcceptAction", reject: "RejectAction" },
        "SME::Interview.ProposeRule"       => { kind: "rule", fields: %w[statement], optional: [],
                                          propose: :propose_rule!, entity: "RuleFinding",
                                          accept: "AcceptRule", reject: "RejectRule" },
        "SME::Interview.ProposeField"      => { kind: "field", fields: %w[thing name values], optional: %w[values],
                                          propose: :propose_field!, entity: "FieldFinding",
                                          accept: "AcceptField", reject: "RejectField" },
        "SME::Interview.ProposeTransition" => { kind: "transition", fields: %w[thing action to from],
                                                optional: %w[from], propose: :propose_transition!,
                                                entity: "TransitionFinding", accept: "AcceptTransition",
                                                reject: "RejectTransition" }
      }.freeze

      TRUE_WORDS = %w[true yes y 1].freeze

      Result = Struct.new(:status, :interview, keyword_init: true)

      # @param runtime [Runtime] the booted SME chapter
      # @param agent [#question, #proposals, nil] the interviewer; nil runs the plain prompts
      # @param input [#gets] where the developer types
      # @param output [#puts, #print] where the session speaks
      # @param reference [String] the interview's reference, such as `INT-1`
      # @param subject [String] the domain being discovered, as its bluebook will spell it
      # @param expert [String] who is being interviewed
      def initialize(runtime:, agent:, input:, output:, reference:, subject:, expert:)
        @runtime = runtime
        @agent = agent
        @input = input
        @output = output
        @reference = reference
        @subject = subject
        @expert = expert
        @asked = []
        @number = 0
        @suggested = false
      end

      # Holds the interview until the developer finishes or quits.
      #
      # @return [Result] `concluded` with the plain interview (see `InterviewDraft`), or `cancelled`
      def call
        ::Interview.plan!(reference: @reference, subject: @subject, expert: @expert).begin!
        say("#{NOTICE}\n") if @agent
        say("Type done when there is enough to start, or quit to stop and write nothing.\n")
        turn until finished?
        outcome
      end

      private

      def outcome
        return Result.new(status: :cancelled) if @cancelled

        Result.new(status: :concluded, interview: InterviewDraft.from_record(current))
      end

      def finished? = @finished

      def current = ::Interview.find(@reference)

      def turn
        question = next_question
        say("\n#{question}")
        answer = ask("> ")
        return end_of_input if answer.nil?

        case answer.strip.downcase
        when "" then say("Say what the expert said, or type done.")
        when "done" then conclude
        when "quit" then cancel
        else answered(question, answer.strip)
        end
      end

      def answered(question, answer)
        current.record!(question: question, answer: answer)
        @asked << question
        findings_from(answer)
        suggest_enough
      end

      def next_question
        asked = @asked.dup
        proposed = @agent && ask_agent { @agent.question(state: state, asked: asked) }
        text = proposed&.text
        return text if text && !@asked.include?(text)

        FALLBACK_QUESTIONS.find { |q| !@asked.include?(q) } || FALLBACK_QUESTIONS.last
      end

      def findings_from(answer)
        proposals = @agent && ask_agent { @agent.proposals(prose: answer, state: state) }
        return manual_findings unless proposals

        proposals.each { |proposal| review(proposal) }
      end

      # Runs one call to the agent; a turn it cannot answer is said aloud, and a plain one follows.
      def ask_agent
        yield
      rescue Ports::Agent::Unavailable, Ports::Agent::ValidationError => e
        say("The AI could not answer (#{e.message.lines.first.to_s.strip}). Using a plain prompt for this turn.")
        nil
      end

      def review(proposal)
        config = KINDS[proposal.verb]
        return say("Ignored a proposal for #{proposal.verb}: not a finding I know.") unless config

        fields = fields_of(proposal, config)
        missing = config[:fields].reject { |f| config[:optional].include?(f) || fields[f].to_s.strip != "" }
        return say("Ignored a #{config[:kind]} proposal with no #{missing.join(", ")}.") unless missing.empty?

        number = propose(config, fields) or return
        say("  Proposed #{describe(config, fields)}")
        say("  because: #{proposal.rationale}")
        decide(config, number, accept?("  Accept? [Y/n] "))
      end

      def fields_of(proposal, config)
        rows = proposal.arguments.to_h { |row| [row[:name].to_s, row[:value]] }
        fields = rows.slice(*config[:fields])
        fields["creates"] = TRUE_WORDS.include?(fields["creates"].to_s.downcase) if fields.key?("creates")
        fields.reject { |key, value| key != "creates" && config[:optional].include?(key) && value.to_s.strip.empty? }
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
        when "action" then "action: #{fields["name"]} on #{fields["thing"]}, announcing #{fields["event"]}" \
                           "#{", creating it" if fields["creates"]}#{action_extras(fields)}"
        when "field" then "field: #{fields["name"]} of #{fields["thing"]}#{", one of #{fields["values"]}" if fields["values"]}"
        when "transition" then "transition: #{fields["action"]} leaves #{fields["thing"]} #{fields["to"]}" \
                               "#{", from #{fields["from"]}" if fields["from"]}"
        else "rule: #{fields["statement"]}"
        end
      end

      # @api private
      def action_extras(fields)
        "#{", taking #{fields["takes"]}" if fields["takes"]}#{", by #{fields["by"]}" if fields["by"]}"
      end

      # The plain prompt: findings typed by the developer, accepted as they are entered.
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

      def suggest_enough
        return if @suggested || !enough?

        @suggested = true
        say("\nI think we have enough to start. Type done to finish, or keep answering.")
      end

      def enough?
        plain = InterviewDraft.from_record(current)
        InterviewDraft.accepted(plain, :things).any? && InterviewDraft.accepted(plain, :actions).any?
      end

      def conclude
        current.conclude!
        @finished = true
      rescue StandardError => e
        say("Not finished yet: #{reason(e)}.")
      end

      def cancel
        current.cancel!
        @cancelled = @finished = true
        say("Stopped. Nothing was written.")
      end

      def end_of_input
        conclude
        cancel unless @finished
      end

      def accept?(label)
        !%w[n no].include?(ask(label).to_s.strip.downcase)
      end

      def state
        plain = InterviewDraft.from_record(current)
        { task: format(TASK, subject: @subject), subject: @subject, expert: @expert, verbs: VERBS,
          exchanges: plain[:exchanges].each_with_index.map { |e, i| e.slice(:question, :answer).merge(number: i + 1) },
          accepted: accepted_state(plain), gaps: gaps(plain) }
      end

      def accepted_state(plain)
        { things:      InterviewDraft.accepted(plain, :things).map { |f| f.slice(:name, :identifier) },
          actions:     InterviewDraft.accepted(plain, :actions).map { |f| f.slice(:name, :thing, :event, :creates, :takes, :by) },
          fields:      InterviewDraft.accepted(plain, :fields).map { |f| f.slice(:thing, :name, :values) },
          transitions: InterviewDraft.accepted(plain, :transitions).map { |f| f.slice(:thing, :action, :to, :from) },
          rules:       InterviewDraft.accepted(plain, :rules).map { |f| f.slice(:statement) } }
      end

      # What the interview has not yet pinned down, in words a model can act on.
      def gaps(plain)
        things = InterviewDraft.accepted(plain, :things).map { |t| t[:name].to_s }
        actions = InterviewDraft.accepted(plain, :actions)
        gaps = things.reject { |t| actions.any? { |a| a[:thing] == t } }.map { |t| "nothing is yet said to happen to #{t}" }
        gaps += things.reject { |t| actions.any? { |a| a[:thing] == t && a[:creates] } }.map { |t| "nothing yet creates #{t}" }
        unplaced = actions.reject { |a| things.include?(a[:thing].to_s) }
        gaps + unplaced.map { |a| "#{a[:name]} names #{a[:thing]}, not yet a thing" } + shape_gaps(plain, things, actions)
      end

      # What a thing is not yet said to have, and how it moves from one state to the next.
      def shape_gaps(plain, things, actions)
        fields = InterviewDraft.accepted(plain, :fields)
        steps = InterviewDraft.accepted(plain, :transitions)
        bare = things.reject { |t| fields.any? { |f| f[:thing] == t } }
        gaps = bare.map { |t| "nothing is yet said #{t} has, beyond its identifier" }
        changing = things.select { |t| actions.count { |a| a[:thing] == t && !a[:creates] } > 1 }
        unmoved = changing.reject { |t| steps.any? { |s| s[:thing] == t } }
        gaps + unmoved.map { |t| "nothing yet says how #{t} moves from one state to the next" }
      end

      def reason(error) = error.message.sub(/\A[A-Z]\w* refused\s+[—-]\s+/, "").strip

      def ask(label)
        @output.print(label)
        @input.gets&.chomp
      end

      def say(text) = @output.puts(text)
    end
  end
end
