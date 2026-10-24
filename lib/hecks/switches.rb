module Hecks
  # The developer switches a process can flip through its environment, read in one place so the
  # runtime and the bluebook layer never read `ENV` themselves.
  #
  # @example
  #   Hecks::Switches.verdict_cache?  # => false under HECKS_VERDICT_CACHE=off
  module Switches
    module_function

    # @return [Boolean] whether rules are evaluated from their canonical string
    #   (`HECKS_EVAL=string`) instead of the cached AST
    def string_evaluation? = ENV["HECKS_EVAL"] == "string"

    # @return [Boolean] whether the syntax-boot table is cached on disk;
    #   `HECKS_SYNTAX_BOOT_CACHE=off` turns it off
    def syntax_boot_cache? = ENV["HECKS_SYNTAX_BOOT_CACHE"] != "off"

    # @return [Boolean] whether meta-validator verdicts are cached on disk;
    #   `HECKS_VERDICT_CACHE=off` turns it off
    def verdict_cache? = ENV["HECKS_VERDICT_CACHE"] != "off"
  end
end
