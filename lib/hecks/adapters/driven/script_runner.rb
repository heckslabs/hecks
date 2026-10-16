require "digest"
require "json"

module Hecks
  module Adapters
    # The `Script` port's adapter for a `Change`: it runs the scripts registered with it, in this
    # process. A script is a name, a `plan` that says what it would do without doing it, and an
    # `apply` that does it.
    #
    # `examine` plans a change and answers the plan with a digest of it. `perform` plans again and
    # carries the change out only when the plan still has the digest that was confirmed, so what
    # runs is what the person saw. A script that cannot be found, or whose plan or apply raises,
    # refuses the change with its message.
    class ScriptRunner
      # A script: what it would do, and doing it. Both take the arguments as a Hash of String keys.
      Script = Struct.new(:plan, :apply, keyword_init: true)

      # Why a change was refused: an unknown script, a plan that moved, or the script's own failure.
      class Refused < StandardError; end

      class << self
        # @return [Hash{String => Script}] the scripts this process can run, by name
        def scripts = @scripts ||= {}

        # @param name [String] the name a change asks for
        # @param plan [#call] takes the arguments, returns the text of what the script would do
        # @param apply [#call] takes the arguments, does it, returns the text of what happened
        # @return [Script] the registered script
        def register(name, plan:, apply:) = scripts[name.to_s] = Script.new(plan: plan, apply: apply)

        # Forgets every registered script.
        #
        # @return [Hash] the empty registry
        def reset! = @scripts = {}
      end

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # Plans the change.
      #
      # @param held [Hash] the record: `script` and `arguments`
      # @return [Hash{Symbol => Hash}] `plan:` what the script would do, and `digest:` its
      #   fingerprint
      # @raise [Refused] when the script is unknown or its plan raises
      def examine(**held)
        name, args = request(held)
        text = planned(name, args)
        { plan: { value: text }, digest: { value: digest(name, args, text) } }
      end

      # Carries out a confirmed change if its plan has not moved.
      #
      # @param held [Hash] the record: `script`, `arguments` and `planned_digest`
      # @return [Hash{Symbol => Hash}] `report:` what the script reported
      # @raise [Refused] when the script is unknown, the plan has moved, or the script raises
      def perform(**held)
        name, args = request(held)
        current = digest(name, args, planned(name, args))
        raise Refused, "the plan moved since it was confirmed; plan it again" unless current == plain(held[:planned_digest])

        { report: { value: run(name, :apply, args).to_s } }
      end

      private

      def request(held) = [plain(held[:script]), arguments(held[:arguments])]

      def planned(name, args) = run(name, :plan, args).to_s

      def run(name, step, args)
        script = self.class.scripts.fetch(name) { raise Refused, "no script is registered as #{name.inspect}" }
        script.public_send(step).call(args)
      rescue Refused
        raise
      rescue StandardError => e
        raise Refused, "#{name} #{step} failed: #{e.message}"
      end

      # The digest stands for the script, its arguments and its plan, so none of them can change
      # between confirming and applying.
      def digest(name, args, text) = Digest::SHA256.hexdigest(JSON.generate([name, args.sort.to_h, text]))

      def arguments(list) = Array(list).to_h { |pair| [plain(pair[:key]), plain(pair[:value])] }

      def plain(cell) = cell.is_a?(Hash) && cell.key?(:value) ? cell[:value] : cell
    end
  end
end
