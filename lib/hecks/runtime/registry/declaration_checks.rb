module Hecks
  module Runtime
    class Registry
      # The wiring checks that read only the loaded declarations, the worlds and the adapter
      # classes, and open no store, so they answer the same every time they run on one registry.
      # A process that boots the same registry many times (a resident's children) runs them
      # once, before it forks; a registry they have passed skips them until a declaration
      # changes. One that fails raises each time, since only a pass is remembered. Mixed into
      # {Verification}.
      module DeclarationChecks
        # The checks, in the order `verify!` has always run them.
        CHECKS = %i[verify_default_adapter! verify_world_defaults! verify_singleton_port_answers!
                    refuse_cross_package_bluebook_merge! refuse_reserved_bluebook_names!
                    refuse_membership_without_identity! refuse_unresolved_ports!
                    refuse_unanswerable_queries!].freeze

        # Runs the checks unless this registry has passed them and nothing was declared since. The
        # reserved-name check runs every time, since the file list it reads is a plain hash a
        # caller can empty without declaring anything, and it costs a few lookups.
        #
        # @return [Registry] self
        # @raise [WiringError] if a check finds a wiring problem
        def verify_declarations!
          if @declared.verified
            refuse_reserved_bluebook_names!
            return self
          end

          CHECKS.each { |check| send(check) }
          @declared.verified = true
          self
        end
      end
    end
  end
end
