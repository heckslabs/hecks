# ActiveHecks
#
# Adds full ActiveModel compatibility to generated domain objects so they
# work seamlessly with Rails. Includes validations, JSON serialization,
# lifecycle callbacks, form helpers, URL helpers, and error display.
#
# This is an optional integration layer -- only needed when using Hecks
# domain gems inside a Rails application.
#
#   require "active_hecks"
#   ActiveHecks.activate(PizzasDomain)
#
#   pizza = Pizza.new(name: "")
#   pizza.valid?          # => false
#   pizza.errors[:name]   # => ["can't be blank"]
#   pizza.as_json         # => {"id" => "...", "name" => "", ...}
#
#   Pizza.before_save { puts "saving!" }
#
# Mixins:
#   BluebookModelCompat   — naming, conversion, JSON serialization (all objects)
#   AggregateCompat     — identity, validations, lifecycle callbacks
#   ValueObjectCompat   — no-identity, immutable semantics
#   ValidationWiring    — converts DSL rules to ActiveModel validates calls
#   PersistenceWrapper  — wraps save/destroy with validation + callbacks
#
require "active_model"

# Load ActiveHecks implementation files from the Rails chapter definition.
require "hecks/chapters/rails"
Hecks::Chapters.load_chapter(
  Hecks::Rails,
  base_dir: File.expand_path("active_hecks", __dir__)
)

module ActiveHecks
  # Activate ActiveModel compatibility on all aggregates and value objects
  # in a generated domain module.
  def self.activate(domain_module, domain: nil)
    @domain = domain

    domain_module.constants.each do |const_name|
      const = domain_module.const_get(const_name)

      if const.is_a?(Class) && !(const < Exception)
        extend_aggregate(const)
        extend_nested_value_objects(const)
      elsif const.is_a?(Module) && !%i[Ports Adapters].include?(const_name)
        const.constants.each do |agg_name|
          agg_class = const.const_get(agg_name)
          next unless agg_class.is_a?(Class) && !(agg_class < Exception)
          extend_aggregate(agg_class)
          extend_nested_value_objects(agg_class)
        end
      end
    end
  ensure
    @domain = nil
  end

  def self.extend_nested_value_objects(klass)
    # Use constants(false) to only get constants defined directly on the class,
    # not those inherited from included modules (like ActiveModel validators).
    klass.constants(false).each do |nested_name|
      nested = klass.const_get(nested_name)
      next unless nested.is_a?(Class) && !(nested < Exception)
      extend_value_object(nested)
    end
  end

  def self.extend_aggregate(klass)
    klass.include(BluebookModelCompat)
    klass.include(AggregateCompat)
    ValidationWiring.bind(klass, domain: @domain)
    override_model_name(klass)
    PersistenceWrapper.bind(klass)
  end

  def self.extend_value_object(klass)
    klass.include(BluebookModelCompat)
    klass.include(ValueObjectCompat)
    override_model_name(klass)
  end

  # Strip the domain module prefix so Pizza is "Pizza", not "PizzasDomain::Pizza"
  def self.override_model_name(klass)
    short_name = klass.name.split("::").last
    klass.define_singleton_method(:model_name) do
      @_model_name ||= ActiveModel::Name.new(self, nil, short_name)
    end
  end
end
