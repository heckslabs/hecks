# Hecks::BluebookRegistryMethods
#
# Domain caching, load strategy, and last_domain tracking.
# Extracted from the Hecks module.
#
module Hecks
  # Hecks::BluebookRegistryMethods
  #
  # Domain caching, load strategy, and last_domain tracking extended onto the Hecks module.
  #
  module BluebookRegistryMethods
    def loaded_bluebooks
      @loaded_bluebooks ||= Registry.new
    end

    def bluebook_objects
      @bluebook_objects ||= Registry.new
    end

    def last_domain
      @last_domain
    end

    def last_domain=(domain)
      @last_domain = domain
    end

    def last_bluebook
      @last_bluebook
    end

    def last_bluebook=(bluebook)
      @last_bluebook = bluebook
    end

    def last_hecksagon
      @last_hecksagon
    end

    def last_hecksagon=(hecksagon)
      @last_hecksagon = hecksagon
    end

    def last_world
      @last_world
    end

    def last_world=(world)
      @last_world = world
    end

    def last_test_suite
      @last_test_suite
    end

    def last_test_suite=(suite)
      @last_test_suite = suite
    end

    # Most recently parsed .fixtures file. Set by Hecks.fixtures.
    # Mirrors last_test_suite — single-shot accessor, not a stack.
    def last_fixtures_file
      @last_fixtures_file
    end

    def last_fixtures_file=(file)
      @last_fixtures_file = file
    end

    def load_strategy
      @load_strategy ||= :memory
    end

    def load_strategy=(strategy)
      @load_strategy = strategy
    end
  end
end
