module Hecks
  module Runtime
    class Registry
      # What a boot gathers while the `.bluebook`, `.hecksagon` and `.world` files load: the
      # chapters and their builders, the wiring, ports, adapters, worlds, translations, the
      # eras the boot gate resolved, and the privacy markings still to be dispatched.
      Declarations = Struct.new(:bluebooks, :bluebook_sources, :hecksagons, :bounded_chapters, :ports,
                                :adapters, :worlds, :translations, :bluebook_builders,
                                :pending_privacy_markings, :resolved_eras, :superseded_eras) do
        # @return [Declarations] every collection empty
        def self.empty
          new({}, {}, {}, {}, {}, {}, {}, [], {}, [], {}, {})
        end
      end
    end
  end
end
