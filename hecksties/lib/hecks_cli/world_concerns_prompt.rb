# Hecks::WorldConcernsPrompt
#
# Interactive onboarding prompt that asks developers to declare world concerns
# for a new domain. Each concern maps to a real Hecks extension that enforces
# the goal at runtime. Extracted from new_project.rb to keep that file small.
#
# Usage:
#   result = WorldConcernsPrompt.run(say_method: method(:say))
#   result[:concerns]   # => [:privacy, :consent]
#   result[:extensions] # => [:pii, :auth]
#   result[:stub]       # => false
#
module Hecks
  # Hecks::WorldConcernsPrompt
  #
  # Interactive prompt for declaring world concerns that map to Hecks extensions during domain init.
  #
  class WorldConcernsPrompt
    GOAL_TO_EXTENSION = {
      privacy:       :pii,
      transparency:  :audit,
      consent:       :auth,
      security:      :auth,
      equity:        :tenancy,
      sustainability: :rate_limit
    }.freeze

    VALID_GOALS = GOAL_TO_EXTENSION.keys.freeze

    GOAL_DESCRIPTIONS = {
      privacy:       "mark sensitive fields, require consent  (extend :pii)",
      transparency:  "log all state changes                   (extend :audit)",
      consent:       "require actors for all commands         (extend :auth)",
      security:      "fail-closed auth and CSRF protection    (extend :auth)",
      equity:        "row-level access, no gatekeeping        (extend :tenancy)",
      sustainability: "rate limiting and resource bounds       (extend :rate_limit)"
    }.freeze

    def initialize(say_method:, stdin: $stdin)
      @say    = say_method
      @stdin  = stdin
    end

    # Run the prompt and return a result hash.
    # Returns { concerns: [], extensions: [], stub: false } on skip.
    # Returns { concerns: [], extensions: [], stub: true } on "doesn't apply".
    def run
      return no_concerns unless @stdin.tty?

      show_welcome
      choice = ask_top_choice
      case choice
      when "1" then walk_through_concerns
      when "3" then { concerns: [], extensions: [], stub: true }
      else          no_concerns
      end
    end

    private

    def show_welcome
      @say.call("")
      @say.call("Welcome to Hecks.")
      @say.call("")
      @say.call("Hecks is built on the belief that software affects living beings.")
      @say.call("The domain you're about to model will touch some of them.")
      @say.call("")
      @say.call("Would you like to declare world concerns for this domain?")
      @say.call("")
      @say.call("  1. Yes — walk me through them")
      @say.call("  2. Skip for now — I'll add them later")
      @say.call("  3. This doesn't apply to my project")
      @say.call("")
    end

    def ask_top_choice
      @stdin.gets&.chomp&.strip || "2"
    end

    def walk_through_concerns
      @say.call("")
      @say.call("Available concerns (each wires in a real extension):")
      @say.call("")
      GOAL_DESCRIPTIONS.each do |goal, desc|
        @say.call("  %-14s — %s" % [goal.to_s, desc])
      end
      @say.call("")
      @say.call("Select concerns (comma-separated, or Enter to skip):")

      raw   = @stdin.gets&.chomp&.strip || ""
      input = raw.split(/[\s,]+/).map { |s| s.to_sym } & VALID_GOALS

      extensions = input.map { |g| GOAL_TO_EXTENSION[g] }.uniq

      { concerns: input, extensions: extensions, stub: false }
    end

    def no_concerns
      { concerns: [], extensions: [], stub: false }
    end
  end
end
