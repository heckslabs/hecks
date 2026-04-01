require "securerandom"
require_relative "runtime_attribute_definition"

module Hecks
  # Hecks::Model
  #
  # Mixin for generated aggregate classes. Declares attributes via a DSL,
  # generates the constructor automatically, and provides identity,
  # validation hooks, auto-discovery, and timestamp support.
  #
  # == Identity
  #
  # Every model instance gets a UUID +id+ assigned at construction (or accepts
  # one via the +id:+ keyword). Two instances are equal (+==+) if they share
  # the same class and id (entity semantics, not value semantics).
  #
  # == Attributes
  #
  # Attributes are declared with +attribute :name, default: nil, freeze: false+.
  # Each call regenerates the constructor so all attributes are accepted as
  # keyword arguments. Pristine values are stored for +#reset!+.
  #
  # == Auto-discovery submodules
  #
  # When included, +Model+ creates submodule constants (+Commands+, +Events+,
  # +Queries+, +Policies+, +Specifications+) on the including class. These
  # submodules use +const_missing+ to autoload domain behavior files by
  # convention (e.g. +Pizza::Commands::CreatePizza+ loads from
  # +pizza/pizza/commands/create_pizza.rb+).
  #
  # == Usage
  #
  #   class Pizza
  #     include Hecks::Model
  #     attribute :name
  #     attribute :description
  #     attribute :toppings, default: []
  #   end
  #
  #   Pizza.hecks_attributes  # => [{name: :name, default: nil}, ...]
  #   Pizza.new(name: "Margherita").name  # => "Margherita"
  #
  module Model
    extend HecksTemplating::NamingHelpers

    # Hook called when a class includes +Hecks::Model+. Sets up identity readers
    # (+id+, +created_at+, +updated_at+), extends the class with the attribute
    # DSL, and creates auto-discovery submodules for commands, events, queries,
    # policies, and specifications.
    #
    # @param base [Class] the class including this module
    # @return [void]
    def self.included(base)
      base.extend(ClassMethods)
      base.attr_reader :id, :created_at, :updated_at
      create_submodule(base, :Commands)
      create_submodule(base, :Events)
      create_submodule(base, :Queries)
      create_submodule(base, :Policies)
      create_submodule(base, :Specifications)
    end

    # Class-level DSL for declaring model attributes.
    module ClassMethods
      include HecksTemplating::NamingHelpers
      # Declares a named attribute with optional default and freeze behavior.
      # Each call to +attribute+ regenerates the constructor to accept the
      # new attribute as a keyword argument. Also defines +attr_reader+ and
      # +attr_writer+ for the attribute.
      #
      # @param name [Symbol, String] the attribute name
      # @param default [Object, nil] default value when the attribute is not provided
      # @param freeze [Boolean] whether to freeze the value after assignment
      # @return [void]
      def attribute(name, default: nil, freeze: false)
        @hecks_attributes ||= []
        @hecks_attributes << RuntimeAttributeDefinition.new(name: name.to_sym, default: default, freeze: freeze)
        attr_reader name
        attr_writer name
        rebuild_initializer
      end

      # Returns the list of declared attribute definitions for this model.
      #
      # @return [Array<RuntimeAttributeDefinition>] attribute definitions, empty array if none declared
      def hecks_attributes
        @hecks_attributes || []
      end

      private

      # Regenerates the +#initialize+ method to accept all currently declared
      # attributes as keyword arguments. Assigns defaults, freezes values when
      # configured, stores pristine copies for +#reset!+, and runs validation.
      #
      # @return [void]
      def rebuild_initializer
        attrs = @hecks_attributes.dup
        define_method(:initialize) do |id: nil, **kwargs|
          @id = id || SecureRandom.uuid
          @_pristine = {}
          attrs.each do |attr|
            val = kwargs.fetch(attr.name, attr.default)
            val = val.freeze if attr[:freeze]
            instance_variable_set(:"@#{attr.name}", val)
            @_pristine[attr.name] = val
          end
          validate!
          check_invariants!
        end
      end
    end

    # Restores all attributes to their constructor values (the pristine snapshot
    # taken at initialization time). Does not reset +id+ or timestamps.
    #
    # @return [self] the model instance with attributes restored
    def reset!
      @_pristine.each do |name, val|
        instance_variable_set(:"@#{name}", val)
      end
      self
    end

    # Sets +created_at+ and +updated_at+ to the current time. Called by the
    # persistence layer when a new aggregate is first saved.
    #
    # @return [void]
    def stamp_created!
      @created_at = Time.now
      @updated_at = @created_at
    end

    # Sets +updated_at+ to the current time. Called by the persistence layer
    # when an existing aggregate is saved again.
    #
    # @return [void]
    def stamp_updated!
      @updated_at = Time.now
    end

    # Returns true if both objects are the same type and share the same id.
    # This implements entity equality (identity-based), not value equality.
    #
    # @param other [Object] the object to compare
    # @return [Boolean]
    def ==(other)
      other.is_a?(self.class) && id == other.id
    end
    alias eql? ==

    # Returns a hash based on class and id for use in Hash keys and Sets.
    # Consistent with +#==+ -- two entities with the same class and id
    # produce the same hash value.
    #
    # @return [Integer]
    def hash
      [self.class, id].hash
    end

    # Returns a concise, human-readable representation of the aggregate.
    #
    # Shows the short class name, truncated id, and all user-defined
    # attribute values. Designed for REPL readability.
    #
    # @return [String] e.g. '#<Pizza id:abc123 name:"Margherita" style:"NY">'
    def inspect
      short_class = self.class.name&.split("::")&.last || self.class.to_s
      short_id = id.to_s[0, 8]
      attrs = self.class.hecks_attributes.map do |attr|
        val = instance_variable_get(:"@#{attr.name}")
        "#{attr.name}: #{val.inspect}"
      end
      "#<#{short_class} id:#{short_id} #{attrs.join(' ')}>"
    end

    alias to_s inspect

    private

    # Validation hook called at the end of +#initialize+. Override in
    # subclasses to raise errors when attribute values are invalid.
    #
    # @return [void]
    def validate!; end

    # Invariant hook called at the end of +#initialize+ after +#validate!+.
    # Override in subclasses to enforce domain invariants.
    #
    # @return [void]
    def check_invariants!; end

    # Maps submodule types to their corresponding mixin modules. When a class
    # is autoloaded within one of these submodules, the mixin is automatically
    # included so DSL methods (+emits+, +where+, +satisfied_by?+, etc.) are
    # available when the file is loaded.
    MIXINS = {
      Commands:       -> { Hecks::Command },
      Queries:        -> { Hecks::Query },
      Specifications: -> { Hecks::Specification },
    }.freeze

    # Creates an auto-discovery submodule on the given base class. The submodule
    # uses +const_missing+ to autoload files by naming convention. For types
    # listed in +MIXINS+, the appropriate mixin is included before the file is
    # loaded so DSL methods are available during class definition.
    #
    # @param base [Class] the model class to create the submodule on
    # @param type [Symbol] the submodule name (+:Commands+, +:Events+, +:Queries+, +:Policies+, +:Specifications+)
    # @return [void]
    def self.create_submodule(base, type)
      return if base.const_defined?(type, false)

      mod = Module.new
      type_dir = domain_snake_name(type.to_s)
      mixin_proc = MIXINS[type]

      snake = method(:domain_snake_name)
      mod.define_singleton_method(:const_missing) do |name|
        parts = base.name.split("::")
        gem_name = snake.call(parts.first)
        agg_name = snake.call(parts.last)
        file_name = snake.call(name.to_s)

        if mixin_proc
          # Pre-create class with mixin so DSL methods (emits, where, etc.)
          # are available when the file is loaded and reopens the class.
          klass = Class.new
          const_set(name, klass)
          klass.include(mixin_proc.call)
          require "#{gem_name}/#{agg_name}/#{type_dir}/#{file_name}"
          klass
        else
          require "#{gem_name}/#{agg_name}/#{type_dir}/#{file_name}"
          const_get(name)
        end
      end

      base.const_set(type, mod)
    end

    private_class_method :create_submodule
  end
end
