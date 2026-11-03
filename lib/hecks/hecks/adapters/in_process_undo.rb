# frozen_string_literal: true

module Hecks
  module Adapters
    # The answer to `Introspection.Undo`, mixed into the in-process boot adapter: the command
    # that undoes a declared command, from the bluebook's compensations (`Projections::Undo`).
    module InProcessUndo
      # @param domain [Hash, String] a domain directory
      # @param bluebook [Hash, String] the bluebook's name
      # @param command [Hash, String] the command's verb form, e.g. "Account.Debit"
      # @return [Hash] `text:` the command that undoes it, or that none is declared
      def undo(domain:, bluebook:, command:)
        report(Projector.call(:undo, bluebook: bluebook_of(domain, bluebook), options: { command: plain(command) }).join("\n"))
      end
    end
  end
end
