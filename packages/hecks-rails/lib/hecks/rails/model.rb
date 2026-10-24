require "active_model"
require_relative "booting"
require_relative "model/verbs"
require_relative "model/availability"

module Hecks
  module Rails
    # Raised by `Model.find` when no record has the identity asked for; Rails answers it with a 404.
    class RecordNotFound < StandardError; end

    # A Rails model over one aggregate: `class Account < Hecks::Rails::Model; aggregate
    # "Banking.Account"; end`.
    #
    # It is thin on purpose. The aggregate's shape, rules and verbs come from the bluebook, and the
    # class adds only what Rails needs to name, route and render a record (ActiveModel's `Naming`,
    # `Conversion` and an `Errors` that refusals are poured into). Presentation methods belong
    # here; a validation, a callback or an association does not, and `HecksRails/ThinModel`
    # refuses them, because each would be a second author for a rule the bluebook holds.
    class Model
      extend ActiveModel::Naming
      extend ActiveModel::Translation
      include ActiveModel::Conversion
      include Availability

      @declared_models = []

      class << self
        # @return [Array<Class>] every model class that has named its aggregate, so a new boot
        #   defines their verbs; read on `Model` itself
        attr_reader :declared_models

        # Names the aggregate this model stands for, or answers it when called with no name.
        #
        # @param qualified [String, nil] the chapter and aggregate, dotted: `"Banking.Account"`
        # @return [String, nil] the qualified name this model stands for
        # @raise [ArgumentError] if the domain is booted and holds no such aggregate
        def aggregate(qualified = nil)
          return @qualified unless qualified

          @qualified = qualified.to_s
          Model.declared_models << self unless Model.declared_models.include?(self)
          define_verbs! if Rails.booted?
          @qualified
        end

        # Defines the readers and verbs of the named aggregate on this class, from the booted IR.
        #
        # @return [void]
        # @raise [ArgumentError] if the domain holds no such aggregate
        def define_verbs! = Verbs.define(self, address)

        # Resolves the named aggregate in the booted domain.
        #
        # @return [Rails::BootedDomain::Address] the chapter's name and the aggregate's IR
        # @raise [Rails::NotBooted] if no domain is booted
        # @raise [ArgumentError] if the domain holds no such aggregate
        def address = Rails.domain.address(@qualified)

        # Finds one record by its identity.
        #
        # @param id [String, Hash] the record's identity, as `to_param` gave it
        # @return [Rails::Model] the record
        # @raise [Rails::RecordNotFound] if no record has that identity
        def find(id)
          handle = Rails.domain.find(address, id)
          handle ? new(handle) : raise(RecordNotFound, "#{address.fqn} #{id.inspect} not found")
        end

        # Lists every record.
        #
        # @return [Array<Rails::Model>] every stored record, in the store's order
        def all = Rails.domain.all(address).map { |handle| new(handle) }

        # Counts the records.
        #
        # @return [Integer] how many records are stored
        def count = Rails.domain.count(address)

        # Finds the model class that stands for an aggregate, if the app declares one.
        #
        # @param address [Rails::BootedDomain::Address] the aggregate
        # @return [Class, nil] the model class; nil when the app declares none
        def for(address)
          Model.declared_models.find { |model| model.aggregate == "#{address.chapter}.#{address.aggregate.hecks_name}" }
        end
      end

      # @return [ActiveModel::Errors] the refusals of the last verb, by attribute or `:base`
      attr_reader :errors

      # @param handle [Adapters::Driving::Handle, nil] the stored record; nil for a model that
      #   stands in for a record a refused creating verb did not make
      def initialize(handle = nil)
        @handle = handle
        @errors = ActiveModel::Errors.new(self)
      end

      # Answers the record's identity.
      #
      # @return [String, nil] the identity; nil when no record stands behind this model
      def id = @handle&.id

      # Answers whether a record stands behind this model.
      #
      # @return [Boolean] true for a found or created record
      def persisted? = !@handle.nil?

      # Reads one stored field's raw value.
      #
      # @param name [Symbol, String] the field's name
      # @return [Object, nil] the stored value; nil when unset
      def [](name) = @handle && @handle[name]

      # Reads a field for an error message, as ActiveModel asks.
      #
      # @param name [Symbol, String] the field's name
      # @return [Object, nil] the stored value
      def read_attribute_for_validation(name) = self[name]

      def to_h = @handle ? @handle.to_h : {}

      # Re-reads the record from its store.
      #
      # @return [Rails::Model] this model
      def reload
        @handle&.reload
        self
      end

      def ==(other) = other.instance_of?(self.class) && !id.nil? && other.id == id

      def inspect = "#<#{self.class.name} #{@handle ? @handle.inspect : "(not stored)"}>"

      private

      attr_reader :handle

      # Runs a non-creating verb through the handle, pouring a refusal into `errors` first.
      def run(command, args)
        errors.clear
        handle.public_send("#{Naming.snake(command.hecks_name)}!", **Verbs.facts(args))
        self
      rescue Hecks::Refused => e
        errors.add(e.attribute || :base, e.message)
        raise
      end
    end
  end
end
