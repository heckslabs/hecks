module Hecks
  module BluebookModel
    module Behavior

    # Hecks::BluebookModel::Behavior::Command
    #
    # Intermediate representation of a domain command -- an intent to change state.
    # Each command carries attributes, optional read models, external systems,
    # and actors. Can infer a corresponding event name by converting the verb
    # to past tense (CreatePizza -> CreatedPizza), or can have explicit event
    # name(s) declared via the +emits+ DSL keyword.
    #
    # Part of the BluebookModel IR layer. Built by CommandBuilder or EventStorm
    # parser, consumed by CommandGenerator and event inference in AggregateBuilder.
    #
    #   cmd = Command.new(name: "CreatePizza", attributes: [])
    #   cmd.inferred_event_name  # => "CreatedPizza"
    #   cmd.event_names          # => ["CreatedPizza"]
    #
    #   cmd2 = Command.new(name: "CreatePizza", emits: ["PizzaCreated", "MenuUpdated"])
    #   cmd2.event_names         # => ["PizzaCreated", "MenuUpdated"]
    #
    class Command
      # @return [String] PascalCase command name, e.g. "CreatePizza"
      # @return [Array<Hecks::BluebookModel::Structure::Attribute>] input attributes for the command
      # @return [String, nil] name of a custom handler class, or nil for default handling
      # @return [String, nil] name of the guard policy to run before execution
      # @return [Array<String>] names of read models this command depends on
      # @return [Array<String>] names of external systems this command interacts with
      # @return [Array<String>] actor roles allowed to invoke this command
      # @return [Proc, nil] custom call body block for the command handler
      # @return [Hash{Symbol => Object}] attribute defaults to set on the aggregate after execution
      # @return [Array<Condition>] preconditions checked before command execution
      # @return [Array<Condition>] postconditions checked after command execution
      # @return [String, Array<String>, nil] explicit event name(s) declared via +emits+
      # @return [String, nil] explicit Ruby method name override (e.g., "sql_type_for"
      #   instead of the default snake_cased command name "map_type")
      attr_reader :method_name

      attr_reader :name, :attributes, :references, :handler, :guard_name, :read_models,
                  :external_systems, :actors, :call_body, :sets,
                  :preconditions, :postconditions, :emits, :description

      # Creates a new Command IR node.
      #
      # @param name [String] PascalCase command name (e.g. "CreatePizza")
      # @param attributes [Array<Hecks::BluebookModel::Structure::Attribute>] input attributes
      # @param handler [String, nil] custom handler class name
      # @param guard_name [String, nil] guard policy name to validate before execution
      # @param read_models [Array<String>] read model names this command references
      # @param external_systems [Array<String>] external system names this command calls
      # @param actors [Array<String>] role names allowed to invoke this command
      # @param call_body [Proc, nil] custom handler body block
      # @param sets [Hash{Symbol => Object}] attribute values to assign on the aggregate post-execution
      # @param preconditions [Array<Condition>] conditions that must hold before execution
      # @param postconditions [Array<Condition>] conditions that must hold after execution
      # @param emits [String, Array<String>, nil] explicit event name(s); nil means infer from command name
      # @return [Command]
      def initialize(name:, attributes: [], references: [], handler: nil, guard_name: nil,
                     read_models: [], external_systems: [], actors: [],
                     call_body: nil, sets: {}, preconditions: [], postconditions: [], emits: nil,
                     description: nil, method_name: nil)
        @name = Names.command_name(name)
        @attributes = attributes
        @references = references
        @handler = handler
        @guard_name = guard_name
        @read_models = read_models
        @external_systems = external_systems
        @actors = actors
        @call_body = call_body
        @sets = sets
        @preconditions = preconditions
        @postconditions = postconditions
        @emits = emits
        @description = description
        @method_name = method_name
      end

      # Returns the event name(s) this command emits.
      # When +emits+ is set explicitly, returns those names as an array.
      # Otherwise returns an array containing the single inferred event name.
      #
      # @return [Array<String>] event names this command emits
      def event_names
        @emits ? Array(@emits) : [inferred_event_name]
      end

      # Lookup table of irregular English verb past tenses, keyed by PascalCase verb.
      # Used by {#inferred_event_name} to handle verbs that don't follow standard
      # "-ed" suffixing rules (e.g. "Send" -> "Sent", "Buy" -> "Bought").
      IRREGULAR_VERBS = {
        "Send" => "Sent", "Build" => "Built", "Buy" => "Bought",
        "Run" => "Ran", "Set" => "Set", "Put" => "Put",
        "Cut" => "Cut", "Hold" => "Held", "Keep" => "Kept",
        "Leave" => "Left", "Make" => "Made", "Pay" => "Paid",
        "Sell" => "Sold", "Tell" => "Told", "Think" => "Thought",
        "Find" => "Found", "Give" => "Gave", "Get" => "Got",
        "Spend" => "Spent", "Lend" => "Lent", "Lose" => "Lost",
        "Win" => "Won", "Write" => "Wrote", "Read" => "Read",
        "Shut" => "Shut", "Hit" => "Hit", "Split" => "Split",
        "Bind" => "Bound", "Bring" => "Brought", "Catch" => "Caught",
        "Choose" => "Chose", "Drive" => "Drove", "Feed" => "Fed",
        "Hear" => "Heard", "Lead" => "Led", "Meet" => "Met",
        "Ride" => "Rode", "Ring" => "Rang", "Rise" => "Rose",
        "Seek" => "Sought", "Shake" => "Shook", "Show" => "Showed",
        "Speak" => "Spoke", "Steal" => "Stole", "Take" => "Took",
        "Teach" => "Taught", "Throw" => "Threw", "Understand" => "Understood",
        "Wake" => "Woke", "Wear" => "Wore", "Withdraw" => "Withdrew",
        "Open" => "Opened", "Offer" => "Offered", "Listen" => "Listened",
        "Enter" => "Entered", "Order" => "Ordered", "Deliver" => "Delivered",
        "Forget" => "Forgot", "Upset" => "Upset", "Offset" => "Offset",
        "Reset" => "Reset", "Broadcast" => "Broadcast", "Cost" => "Cost",
        "Burst" => "Burst", "Hurt" => "Hurt", "Quit" => "Quit",
      }.freeze

      # Set of multi-syllable verbs whose final consonant doubles in past tense.
      # For example, "Submit" -> "Submitted", "Refer" -> "Referred".
      # Used by {#inferred_event_name} as a special case before applying
      # the default "-ed" suffix rule.
      DOUBLE_FINAL = %w[
        Submit Admit Permit Commit Emit Omit Remit Transmit
        Refer Confer Defer Infer Prefer Transfer
        Occur Recur Incur Concur
        Compel Expel Repel Propel
        Control Patrol Enrol Fulfil
        Begin Regret Abet Embed Equip
        Overlap Unwrap Outfit Outrun Outwit
      ].to_set.freeze

      # Converts the command verb to past tense to derive the corresponding
      # domain event name. Splits the PascalCase name on uppercase boundaries,
      # converts the leading verb to past tense, and rejoins the remaining
      # noun segments.
      #
      # The conversion handles three categories:
      # 1. Irregular verbs via the {IRREGULAR_VERBS} lookup table
      # 2. Verbs ending in consonant+y (e.g. "Deny" -> "Denied")
      # 3. Verbs ending in "e" (e.g. "Create" -> "Created")
      # 4. Verbs requiring doubled final consonant (e.g. "Submit" -> "Submitted")
      # 5. Default: append "ed" (e.g. "Add" -> "Added")
      #
      # @return [String] the inferred past-tense event name (e.g. "CreatedPizza")
      #
      # @example
      #   Command.new(name: "CreatePizza").inferred_event_name  # => "CreatedPizza"
      #   Command.new(name: "SubmitOrder").inferred_event_name  # => "SubmittedOrder"
      #   Command.new(name: "SendInvoice").inferred_event_name  # => "SentInvoice"
      def inferred_event_name
        verb, *rest = name.split(/(?=[A-Z])/)
        past_tense = if IRREGULAR_VERBS.key?(verb)
                       IRREGULAR_VERBS[verb]
                     elsif verb =~ /[^aeiou]y$/i
                       verb.sub(/y$/i, "ied")
                     elsif verb =~ /e$/
                       "#{verb}d"
                     elsif DOUBLE_FINAL.include?(verb) || (verb.scan(/[aeiou]/i).length == 1 && verb =~ /[aeiou][^aeiouwxy]\z/i && verb[-1] != verb[-2])
                       "#{verb}#{verb[-1]}ed"
                     else
                       "#{verb}ed"
                     end
        rest.unshift(past_tense).join
      end
    end
    end
  end
end
