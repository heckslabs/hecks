module Hecks
  module Fuzzing
    module Properties
      # Property: how each declared read model is addressed.
      module ReadModelNames
        # An acronym run followed by a capitalised word, as `HTTPServer`, capturing both.
        ACRONYM_BOUNDARY = /([A-Z]+)([A-Z][a-z])/
        # A lowercase letter or digit followed by an uppercase one, capturing both.
        CAMEL_BOUNDARY = /([a-z\d])([A-Z])/

        # Every read model resolves from either spelling of its name, to itself, and no two read
        # models of one chapter share a `query_name`.
        #
        # @param history [Hash] a replayed history, as returned by `Fuzzing::Replay.call`
        # @return [true, String] true, or a message naming each read model that drifts
        def read_model_names_resolve_uniquely(history)
          offenders = (history[:bluebooks] || {}).each_value.flat_map { |bluebook| name_offenders(bluebook) }
          offenders.empty? || offenders.join("; ")
        end

        def name_offenders(bluebook)
          models = bluebook.read_models
          models.flat_map { |model| model_name_offenders(bluebook, model) } + shared_query_names(bluebook, models)
        end

        def model_name_offenders(bluebook, model)
          [drifted_name(model), unresolved_name(bluebook, model)].compact
        end

        def drifted_name(model)
          return if model.query_name == snake_of(model.name)

          "#{model.name}'s query_name is #{model.query_name.inspect}, not #{snake_of(model.name).inspect}"
        end

        def unresolved_name(bluebook, model)
          return if [model.name, model.query_name].all? { |spelling| bluebook.read_model(spelling).equal?(model) }

          "#{model.name} does not resolve to itself by name or by query_name"
        end

        def shared_query_names(bluebook, models)
          models.group_by(&:query_name).select { |_name, held| held.size > 1 }.map do |name, held|
            "#{bluebook.name} declares #{held.map(&:name).join(" and ")} under one query name #{name.inspect}"
          end
        end

        # Written out here rather than called, so a drift in `Naming.snake` is a finding.
        def snake_of(text)
          acronyms_split = text.to_s.gsub(ACRONYM_BOUNDARY, '\1_\2')
          acronyms_split.gsub(CAMEL_BOUNDARY, '\1_\2').downcase
        end
      end
    end
  end
end
