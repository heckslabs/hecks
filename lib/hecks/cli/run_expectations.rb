module Hecks
  module CLI
    # Judges a `hecks run` report against the script's `expectations`: the events that must
    # appear, the refusals that must happen, and the instance fields that must hold.
    module RunExpectations
      module_function

      # Every expectation the report does not meet, each as a sentence.
      #
      # @param expectations [Hash] the script's `"event_names"`, `"refusals"` and `"instances"`
      # @param report [Hash] the run's `:events`, `:refusals` and `:instances`
      # @return [Array<String>] one line per unmet expectation; empty when all are met
      def unmet(expectations, report)
        unmet_events(expectations, report) +
          unmet_refusals(Array(expectations["refusals"]), report[:refusals]) +
          unmet_instances(expectations["instances"] || {}, report[:instances])
      end

      # @api private
      def unmet_events(expectations, report)
        missing = Array(expectations["event_names"]) - report[:events].map { |event| event[:name] }
        missing.empty? ? [] : ["matrix expected events missing: #{missing.join(", ")}"]
      end

      # @api private
      def unmet_refusals(expected_refusals, refusals)
        expected_refusals.filter_map { |expected| missing_refusal(expected, refusals) }
      end

      # A refusal that changed its words is a different story from one that never happened, so
      # the actual errors are printed beside the wanted one.
      #
      # @api private
      def missing_refusal(expected, refusals)
        verb = expected.fetch("verb")
        matched = refusals.any? do |refusal|
          refusal[:verb] == verb && refusal[:error].include?(expected.fetch("includes"))
        end
        return if matched

        said = refusals.select { |refusal| refusal[:verb] == verb }.map { |refusal| refusal[:error] }.uniq
        "matrix expected refusal missing: #{expected}\n  #{verb} actually refused with: #{refusal_words(said)}"
      end

      # @api private
      def refusal_words(said)
        said.empty? ? "(nothing — every attempt was accepted)" : said.inspect
      end

      # @api private
      def unmet_instances(expected_instances, instances)
        expected_instances.flat_map do |key, fields|
          actual = instances[key] || {}
          fields.filter_map do |field, value|
            next if actual[field.to_sym] == value

            "matrix expected #{key}.#{field}=#{value.inspect}, got #{actual[field.to_sym].inspect}"
          end
        end
      end
    end
  end
end
