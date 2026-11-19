module Hecks
  module Bluebook
    module ModelCheck
      # The check over a command's `creates_or_acts`: it is a creating command that acts on the
      # record its identity already names. A command that declares `reference_to` never creates,
      # and an aggregate whose lifecycle frees ended ids (`:reusable`) would have Ruby archive
      # an occupant the Rust kernel acts on, so both are refused as findings.
      module CreatesOrActsChecks
        # One finding per aggregate command that says `creates_or_acts` where it cannot hold.
        #
        # @param bluebook [Bluebook::Declaration] the domain being checked
        # @return [Array<Finding>] a `:misplaced_creates_or_acts` error for each such command
        def creates_or_acts_findings(bluebook)
          bluebook.aggregates.flat_map do |aggregate|
            aggregate.commands.select(&:creates_or_acts?).filter_map do |command|
              reason = creates_or_acts_conflict(aggregate, command)
              reason && misplaced_creates_or_acts_finding(aggregate, command, reason)
            end
          end
        end

        # @return [String, nil] why the command cannot create or act, or nil when it can
        def creates_or_acts_conflict(aggregate, command)
          return "it declares reference_to, so it never creates" unless command.creates?

          lifecycle = aggregate.lifecycle
          return unless lifecycle&.marked(:reusable)

          "#{aggregate.hecks_name} marks ended states :reusable, which frees an occupied id"
        end

        # @return [Finding] the error naming the command and why the word does not hold
        def misplaced_creates_or_acts_finding(aggregate, command, reason)
          Finding.new(kind: :misplaced_creates_or_acts, severity: :error,
                      subject: "#{aggregate.hecks_name}.#{command.hecks_name}",
                      message: "creates_or_acts, but #{reason}")
        end
      end
    end
  end
end
