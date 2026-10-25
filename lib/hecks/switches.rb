module Hecks
  # The developer switches a process can flip through its environment, read in one place so the
  # runtime and the bluebook layer never read `ENV` themselves.
  #
  # A switch that turns a cache off is deprecated: `hecks test_suite_run.clear_caches!` empties the
  # caches, which is how a cache is ruled out as the cause. Setting one still works and says so once.
  #
  # @example
  #   Hecks::Switches.verdict_cache?  # => false under HECKS_VERDICT_CACHE=off
  module Switches
    module_function

    # @return [Boolean] whether the syntax-boot table is cached on disk;
    #   `HECKS_SYNTAX_BOOT_CACHE=off` turns it off
    def syntax_boot_cache? = !turned_off?("HECKS_SYNTAX_BOOT_CACHE")

    # @return [Boolean] whether meta-validator verdicts are cached on disk;
    #   `HECKS_VERDICT_CACHE=off` turns it off
    def verdict_cache? = !turned_off?("HECKS_VERDICT_CACHE")

    # Whether a cache switch is set to `off`, saying once per process that the switch is deprecated.
    #
    # @param name [String] the environment variable
    # @return [Boolean]
    def turned_off?(name)
      return false unless ENV[name] == "off"

      deprecate(name)
      true
    end

    # @param name [String] the environment variable that is deprecated
    # @return [nil]
    def deprecate(name)
      @deprecated ||= {}
      return if @deprecated[name]

      @deprecated[name] = true
      warn "[hecks] #{name} is deprecated: run `hecks test_suite_run.clear_caches!` to rule a cache out"
    end
  end
end
