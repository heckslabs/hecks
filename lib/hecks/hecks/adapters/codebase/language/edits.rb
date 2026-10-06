# frozen_string_literal: true

module Hecks
  module Adapters
    module Codebase
      module Language
        # The edits a word or argument operation makes to the syntax tables, through
        # {Grammar::Evolve}.
        module Edits
          module_function

          # Makes one edit to the syntax tables.
          #
          # @param operation [String] a word or argument operation
          # @param args [Hash] the record's plain fields
          # @return [void]
          # @raise [Grammar::Evolve::Refusal] when the tables refuse the edit
          def edit(operation, args)
            case operation
            when "propose" then propose(args)
            when "rename" then rename(args)
            when "propose_argument" then propose_argument(args)
            when "admit", "deprecate", "retire" then set_status(operation, args)
            else set_argument_status(operation, args)
            end
          end

          # @param args [Hash] the record's plain fields
          # @return [void]
          def propose(args)
            Grammar::Evolve.propose(word: args[:word], context: args[:context], body: args[:body] || "none",
                                    inner: args[:inner] || "", opens: args[:opens] || "", fills: args[:fills] || "")
          end

          # @param args [Hash] the record's plain fields
          # @return [void]
          # @raise [Grammar::Evolve::Refusal] when no new name was given
          def rename(args)
            to = args[:new_name] or refuse("a rename goes somewhere: new_name=")
            Grammar::Evolve.rename(word: args[:word], context: args[:context], to: to)
          end

          # @param args [Hash] the record's plain fields
          # @return [void]
          def propose_argument(args)
            Grammar::Evolve.propose_argument(keyword: args[:word], context: args[:context], kind: args[:kind],
                                             required: args[:required] || "false", at: args[:at] || "",
                                             named: args[:named] || "", fills: args[:fills] || "",
                                             pairs_shape: args[:pairs_shape])
          end

          # @param operation [String] `admit`, `deprecate` or `retire`
          # @param args [Hash] the record's plain fields
          # @return [void]
          def set_status(operation, args)
            Grammar::Evolve.set_status(word: args[:word], context: args[:context], to: STATUSES.fetch(operation))
          end

          # @param operation [String] the argument form of `admit`, `deprecate` or `retire`
          # @param args [Hash] the record's plain fields
          # @return [void]
          def set_argument_status(operation, args)
            Grammar::Evolve.set_argument_status(keyword: args[:word], context: args[:context],
                                                to: STATUSES.fetch(operation), at: args[:at] || "",
                                                named: args[:named] || "")
          end

          # @param message [String] why the edit cannot be made
          # @raise [Grammar::Evolve::Refusal] always
          def refuse(message) = raise(Grammar::Evolve::Refusal, message)
        end
      end
    end
  end
end
