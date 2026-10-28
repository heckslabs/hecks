module Hecks
  module Grammar
    # Replays the translation execution ledger through the translation bluebook's own commands and
    # reads back how each admitted rule kind executes in a target. Extended onto `Hecks::Grammar`.
    module TranslationLedger
      TRANSLATION_LEDGER = File.expand_path("translation_rules.json", __dir__)

      # Boots the translation bluebook and replays the execution ledger through its real commands; a
      # refused step raises.
      #
      # @return [Runtime::Dispatcher] the dispatcher bound to the booted, replayed bluebook
      # @raise [Runtime::WiringError] if the bluebook's own domain rules refuse a ledger step
      def translation
        registry = Runtime::Registry.new
        load_bluebook(registry, File.join(DIR, "translation.bluebook"))
        dispatcher = Runtime::Dispatcher.new(registry)
        JSON.parse(File.read(TRANSLATION_LEDGER)).fetch("steps").each { |step| replay_step(dispatcher, step) }
        dispatcher
      end

      # How every admitted rule kind executes in one target.
      #
      # @param target [String, Symbol] `"postgres"`, `"sqlite"` or `"in_process"`
      # @param dispatcher [Runtime::Dispatcher] a dispatcher bound to the replayed translation
      #   bluebook; defaults to booting and replaying a fresh one
      # @return [Hash{String => String}] rule kind to its form in `target`, for each admitted kind
      #   that executes there
      def rule_executions(target, dispatcher = translation)
        admitted_rules(dispatcher).each_with_object({}) do |rule, forms|
          execution = Array(rule[:executions]).find { |candidate| candidate[:target] == target.to_s }
          forms[rule[:kind].value] = execution[:form] if execution
        end
      end

      # @param dispatcher [Runtime::Dispatcher] a dispatcher bound to the replayed translation
      #   bluebook
      # @return [Array<Runtime::Instance>] every admitted `Rule`, in proposal order
      def admitted_rules(dispatcher)
        registry  = dispatcher.registry
        aggregate = registry.bluebook("Translation").aggregate("Rule")
        registry.repository("Translation", aggregate).all.select { |rule| rule[:status] == "admitted" }
      end
    end
  end
end
