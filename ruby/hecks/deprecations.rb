# Hecks::Deprecations
#
# Registry for deprecated APIs. Registers warning shims onto target classes.
#
module HecksDeprecations
  @registry = []

  def self.register(target_class, method_name, &shim)
    mod = Module.new { define_method(method_name, &shim) }
    target_class.prepend(mod)
    @registry << { target: target_class, method: method_name }
  end

  def self.registered
    @registry.dup
  end

  def self.warn_deprecated(klass, method)
    warn "[DEPRECATION] #{klass}##{method} is deprecated. Use attribute accessors instead."
  end
end

require "hecks/chapters/runtime/mixins"
Hecks::Chapters.load_aggregates(
  Hecks::Runtime::Mixins,
  base_dir: File.expand_path("deprecations", __dir__)
)
