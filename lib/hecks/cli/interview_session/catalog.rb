module Hecks
  module CLI
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
    end
  end
end
