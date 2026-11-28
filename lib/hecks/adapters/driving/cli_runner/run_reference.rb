module Hecks
  module Adapters
    module Driving
      module CliRunner
        # The run key a creating command is owed, and the ids a result names.
        module RunReference
          # The arguments a result names as the ids a command used.
          IDENTITY = %i[run from checkout branch].freeze

          module_function

          # Mints the run key a creating command is owed.
          #
          # @return [Array(Hash, String, nil)] the arguments and the minted key, if one was minted
          def prepare(runtime, spec, args, settings) = LauncherOptions.run_key(runtime, spec, args, settings)

          # The ids a result names: the run key, the record written, and the references the command
          # used. Absent ones are left out.
          #
          # @param args [Hash] the arguments the command ran with
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
