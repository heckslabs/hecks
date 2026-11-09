require "stringio"

module Hecks
  module Adapters
    module Driving
      module Resident
        # The domains a resident has loaded, by directory and `HECKS_ENVIRONMENT`. The overlay an
        # environment names is part of what loads, so each pair is its own entry. The resident fills
        # it in its own process, and a forked child only reads it.
        class DescribedCache
          def initialize
            @held = {}
            @first_printed = nil
          end

          # @param path [String] a domain directory
          # @param environment [String, nil] the value of `HECKS_ENVIRONMENT`
          # @return [Hecks::Runtime::Loader::Described, nil] what was loaded, or nil
          def fetch(path, environment) = @held[[File.expand_path(path), environment]]

          # @return [String] what the first load printed on standard error. A cold launcher
          #   prints it once per run, at its first load of any domain, so a child prints it once
          #   per line; a later load in the resident prints nothing, since the warnings are said
          #   once per process.
          def printed(_path, _environment) = @first_printed.to_s

          # Loads a domain and everything its registry holds, once, under the named environment.
          #
          # @return [Hecks::Runtime::Loader::Described]
          def load(path, environment)
            key = [File.expand_path(path), environment]
            @held[key] ||= under(environment) { quietly { verified(Hecks.describe(path).tap(&:registry)) } }
          end

          private

          # Runs the wiring checks that read only the declarations, once, so no child that boots
          # this domain runs them again. A domain that fails them is held as it is: each child
          # checks it for itself and refuses, with the words a cold launcher would use.
          def verified(described)
            described.registry.verify_declarations!
            described
          rescue StandardError
            described
          end

          def quietly
            saved = $stderr
            $stderr = StringIO.new
            yield
          ensure
            text = $stderr.string
            @first_printed ||= text unless text.empty?
            $stderr = saved
          end

          def under(environment)
            saved = ENV.fetch("HECKS_ENVIRONMENT", nil)
            set(environment)
            yield
          ensure
            set(saved)
          end

          def set(environment)
            environment ? ENV["HECKS_ENVIRONMENT"] = environment : ENV.delete("HECKS_ENVIRONMENT")
          end
        end
      end
    end
  end
end
