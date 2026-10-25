module Hecks
  module Rails
    # A Rails model over a domain aggregate. The railtie generates one per aggregate, so write
    # `class Account < ApplicationRecord` only to hold presentation methods; the aggregate is
    # found by the class name. It is a thin skin with no rules: `validates`, callbacks and
    # associations belong in the bluebook, and `Hecks/RailsModelRules` refuses them.
    #
    # A creating command is a class method (`Account.open_account!`), any other an instance
    # method (`account.freeze_account!`), and the bare name answers the command's declaration.
    class Model
      # No record has the identity asked for.
      class RecordNotFound < Hecks::Refused
        # @return [Symbol] `:not_found`
        def kind = :not_found
      end

      extend ActiveModel::Naming
      extend ActiveModel::Translation
      include ActiveModel::Conversion

      # @return [ActiveModel::Errors] a container refusals are poured into, never a rule's author
      attr_reader :errors

      class << self
        # Binds a named subclass to the aggregate of the same name, so `class Account <
        # ApplicationRecord` needs no declaration.
        #
        # @param subclass [Class] the model class being defined
        # @return [void]
        def inherited(subclass)
          super
          subclass.send(:bind_by_name)
        end

        # Binds this model to an aggregate and defines a method per command.
        #
        # @param name [String] `"Chapter.Aggregate"` or `"Chapter::Aggregate"`
        # @return [void]
        def aggregate(name)
          @door = Booted.door(*name.to_s.split(/\.|::/, 2))
          @door.ir.commands.each { |command| define_command(command) }
        end

        # @return [Module] the aggregate's module in the booted domain
        attr_reader :door

        # @param id [String] the record's identity
        # @return [Model] the record
        # @raise [RecordNotFound] when no such record exists
        def find(id) = new(door.find(id) || raise(RecordNotFound, "no #{model_name.human} #{id}"))

        # @return [Array<Model>] every record
        def all = door.all.map { |handle| new(handle) }

        # @return [Model] a record that is not saved, to carry the refusal of a creating command
        def unsaved = new(nil)

        private

        def bind_by_name
          return unless name && Booted.booted?

          chapter = Booted.app_chapters.find { |candidate| candidate.aggregates.any? { |a| a.hecks_name == name } }
          aggregate("#{chapter.name}.#{name}") if chapter
        end

        def define_command(command)
          name = Naming.snake(command.hecks_name).to_s
          return define_creator(name, command) if command.creates?

          define_method(name) { command }
          define_method("#{name}!") do |**args|
            @handle.public_send("#{name}!", **args)
            self
          end
        end

        def define_creator(name, command)
          define_singleton_method(name) { command }
          define_singleton_method("#{name}!") { |**args| new(door.public_send("#{name}!", **args)) }
        end
      end

      # @param handle [Object, nil] the record in hand, or nil for an unsaved one
      def initialize(handle)
        @handle = handle
        @errors = ActiveModel::Errors.new(self)
      end

      # @return [Boolean] whether the record exists in the domain
      def persisted? = !@handle.nil?

      # @return [String, nil] the record's identity
      def id = @handle&.id

      # @return [String, nil] the identity as a URL segment
      def to_param = id&.to_s

      # @return [Hash{Symbol => Object}] every field the record holds, plus `:id`
      def to_h = @handle ? @handle.to_h : {}

      # Reads a field for `errors`, which asks for the attribute a refusal names.
      #
      # @param attribute [Symbol, String] a field name
      # @return [Object, nil] its value
      def read_attribute_for_validation(attribute) = respond_to?(attribute) ? public_send(attribute) : nil

      # @return [Boolean] whether the record holds or answers the name
      def respond_to_missing?(name, include_private = false) = @handle.respond_to?(name) || super

      # Reads a field through to the record in hand.
      def method_missing(name, ...)
        return @handle.public_send(name, ...) if @handle.respond_to?(name)

        super
      end

      # @param as [String] the actor whose grants decide which commands pass
      # @return [Array<Symbol>] the commands that would pass for that actor right now
      def available_commands(as:) = AvailableCommands.new(self.class.door, @handle).call(actor_id: as)
    end
  end
end
