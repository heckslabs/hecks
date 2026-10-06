# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module TranslationScaffold
      # Says what the written edge file leaves to decide.
      module Reporting
        # @return [void]
        def report(path, diffed)
          text = File.read(path)
          unresolved = text.scan(/^\s*unresolved /).size
          unclaimed = diffed ? diffed[:unclaimed] : []
          puts "wrote #{path}"
          unclaimed.each { |name| puts unclaimed_message(name) }
          verdict = verdict_message(unresolved, unclaimed)
          puts verdict if verdict
        end

        def unclaimed_message(name)
          "UNCLAIMED: #{name} existed and now doesn't, and its successor is ambiguous — " \
            "add `aggregate \"NewName\", was: #{name.inspect}` (with its rules) or " \
            "`retired #{name.inspect}` by hand."
        end

        # @return [String, nil] what is left to decide, nil when unclaimed names say it all
        def verdict_message(unresolved, unclaimed)
          if unresolved.zero? && unclaimed.empty?
            "0 unresolved — this shape change costs one extra boot and no typing. " \
              "Check it with hecks audit_translation, then boot."
          elsif unresolved.positive?
            "#{unresolved} unresolved — decide what each became (rename/move/convert/drop, or " \
              "compute on PostgresEra), then boot."
          end
        end
      end
    end
  end
end
