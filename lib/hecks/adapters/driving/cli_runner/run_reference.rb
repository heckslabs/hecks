require_relative "../../../storehouse"

module Hecks
  module Adapters
    module Driving
      module CliRunner
        # Lets a landing name the linked worktree it lands by its run id, rather than repeating its
        # checkout and branch. An explicit checkout or branch always wins over the one the worktree holds.
        module RunReference
          # The aggregate whose record a landing's `from` names.
          SOURCE = "LinkedTree".freeze

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
          # @return [Hash] the arguments, with checkout and branch filled from the named worktree when the
          #   caller gave a `from` and left them out
          def fill(runtime, spec, args)
            from = args[:from]&.fetch(:value, nil)
            return args unless from && spec[:command].to_s.match?(LANDING)

            tree = Storehouse.state(runtime: runtime, aggregate: SOURCE, id: from,
                                    summary: "landing reads the worktree it names")
            return args unless tree[:ok]

            record = tree[:record]
            args.merge(checkout: args[:checkout] || { value: record[:path] },
                       branch:   args[:branch] || { value: record[:branch] })
          end
        end
      end
    end
  end
end
