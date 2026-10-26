module Hecks
  # The switches a test process can flip through its environment, read in one place so the
  # runtime and the bluebook layer never read `ENV` themselves.
  #
  # Each turns a cache off for a child process that must boot uncached. A person ruling a cache
  # out as the cause empties it instead, with `hecks test_suite_run.clear_caches!`.
  #
  # @example
  #   Hecks::Switches.verdict_cache?  # => false under HECKS_VERDICT_CACHE=off
  module Switches
    module_function

    # @return [Boolean] whether the syntax-boot table is cached on disk;
    #   `HECKS_SYNTAX_BOOT_CACHE=off` turns it off
    def syntax_boot_cache? = ENV["HECKS_SYNTAX_BOOT_CACHE"] != "off"

    # @return [Boolean] whether meta-validator verdicts are cached on disk;
    #   `HECKS_VERDICT_CACHE=off` turns it off
    def verdict_cache? = ENV["HECKS_VERDICT_CACHE"] != "off"
  end
end
