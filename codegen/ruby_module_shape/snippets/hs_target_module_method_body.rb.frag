        @targets[name.to_s] or raise ArgumentError,
          "unknown specializer target: #{name.inspect}. " \
          "Known: #{targets.join(', ')}"
