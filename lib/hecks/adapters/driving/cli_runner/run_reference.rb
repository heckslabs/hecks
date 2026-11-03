require_relative "../../../storehouse"

module Hecks
  module Adapters
    module Driving
      module CliRunner
        # Lets a landing name the linked worktree it lands by its run id, rather than repeating its
        # checkout and branch. An explicit checkout or branch always wins over the one the worktree
        # holds.
        module RunReference
          # The aggregate whose record a landing's `from` names.
          SOURCE = "LinkedTree".freeze

          # The arguments a result names as the ids a command used.
          IDENTITY = %i[run from checkout branch].freeze

          # The command that lands a branch: `Hecks::Landing.Land`, and its qualified forms.
          LANDING = /Landing\.Land\z/

          module_function

          # Mints the run key a creating command is owed, then fills the arguments a `from` names.
          #
          # @return [Array(Hash, String, nil)] the arguments and the minted key, if one was minted
          def prepare(runtime, spec, args, settings)
            args, minted = LauncherOptions.run_key(runtime, spec, args, settings)
            [fill(runtime, spec, args), minted]
          end

          # @param runtime [Runtime::Registry] the booted domain the command runs against
          # @param spec [Hash] the resolved command
          # @param args [Hash] the parsed arguments, keyed by name
          # @return [Hash] the arguments, with checkout and branch filled from the named worktree
          #   when the
          #   caller gave a `from` and left them out
          def fill(runtime, spec, args)
            from = args[:from]&.fetch(:value, nil)
            return args unless from && spec[:command].to_s.match?(LANDING)

            tree = Storehouse.state(runtime: runtime, aggregate: SOURCE, id: from,
                                    summary: "landing reads the worktree it names")
            return args unless tree[:ok]

            record = tree[:record]
            args.merge(checkout: args[:checkout] || { value: value_of(record[:path]) },
                       branch:   args[:branch] || { value: value_of(record[:branch]) })
          end

          # The ids a result names: the run key, the record written, and the references the command
          # used,
          # with the checkout and branch it resolved. Absent ones are left out.
          #
          # @param args [Hash] the arguments the command ran with, after any reference was filled
          # @param record_id [String, nil] the id of the record the command wrote
          # @return [Hash] the ids the command used
          def ids(args, record_id)
            named = IDENTITY.to_h { |key| [key, value_of(args[key])] }
            named.merge(id: record_id).compact
          end

          # A stored field is its value, or the `{value:}` wrapper a word carries.
          def value_of(field)
            field.is_a?(Hash) ? field[:value] : field
          end
        end
      end
    end
  end
end
