# __DOMAIN_MODULE__::Runtime::Model
#
# Mixin for aggregate classes. Declares attributes via a DSL, generates
# the constructor automatically, and provides identity (UUID), validation
# hooks, timestamps, and auto-discovery submodules.

require "securerandom"

module __DOMAIN_MODULE__
  module Runtime
    module Model
      def self.included(base)
        base.extend(ClassMethods)
        base.attr_reader :id, :created_at, :updated_at
        create_submodule(base, :Commands)
        create_submodule(base, :Events)
        create_submodule(base, :Queries)
        create_submodule(base, :Policies)
        create_submodule(base, :Specifications)
      end

      module ClassMethods
        def attribute(name, default: nil, freeze: false)
          @domain_attributes ||= []
          @domain_attributes << { name: name.to_sym, default: default, freeze: freeze }
          attr_reader name
          attr_writer name
          rebuild_initializer
        end

        def domain_attributes
          @domain_attributes || []
        end

        private

        def rebuild_initializer
          attrs = @domain_attributes.dup
          define_method(:initialize) do |id: nil, **kwargs|
            @id = id || SecureRandom.uuid
            @_pristine = {}
            attrs.each do |attr|
              val = kwargs.fetch(attr[:name], attr[:default])
              val = val.freeze if attr[:freeze]
              instance_variable_set(:"@#{attr[:name]}", val)
              @_pristine[attr[:name]] = val
            end
            validate!
            check_invariants!
          end
        end
      end

      def reset!
        @_pristine.each { |name, val| instance_variable_set(:"@#{name}", val) }
        self
      end

      def stamp_created!
        @created_at = Time.now
        @updated_at = @created_at
      end

      def stamp_updated!
        @updated_at = Time.now
      end

      def ==(other)
        other.is_a?(self.class) && id == other.id
      end
      alias eql? ==

      def hash
        [self.class, id].hash
      end

      private

      def validate!; end
      def check_invariants!; end

      MIXIN_MAP = {
        Commands:       -> { __DOMAIN_MODULE__::Runtime::Command },
        Queries:        -> { __DOMAIN_MODULE__::Runtime::Query },
        Specifications: -> { __DOMAIN_MODULE__::Runtime::Specification },
      }.freeze

      def self.underscore(str)
        str.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
           .gsub(/([a-z\d])([A-Z])/, '\1_\2')
           .downcase
      end

      def self.create_submodule(base, type)
        return if base.const_defined?(type, false)

        mod = Module.new
        type_dir = underscore(type.to_s)
        mixin_proc = MIXIN_MAP[type]

        mod.define_singleton_method(:const_missing) do |name|
          parts = base.name.split("::")
          gem_name = Runtime::Model.underscore(parts.first)
          agg_name = Runtime::Model.underscore(parts.last)
          file_name = Runtime::Model.underscore(name.to_s)

          if mixin_proc
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
end
