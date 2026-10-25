module Hecks
  module Rails
    # Asking the domain whether a command would be accepted, and keeping the answer on the record
    # the way Rails keeps validation errors: in `errors`, and against the form field it is about.
    module Validating
      # Whether the command would be accepted for these parameters right now, advisory: the real
      # dispatch stays authoritative. Fills `errors` with every reason it would not be.
      #
      # @param verb [Symbol, String] the command's bare verb, such as `:freeze_account`
      # @param params [ActionController::Parameters, Hash] the request's parameters
      # @return [Boolean] whether nothing refused
      def valid_for?(verb, params = {})
        validate_command(verb, params).empty?
      end

      # The reasons the command would be refused, as the domain gives them, each added to `errors`.
      #
      # @param verb [Symbol, String] the command's bare verb
      # @param params [ActionController::Parameters, Hash] the request's parameters
      # @return [Array<Hecks::Refused>] every refusal, in the order dispatch would find them
      def validate_command(verb, params = {})
        command = self.class.command_named(verb)
        refusals = Booted.dispatcher.validate("#{self.class.door.fqn}.#{command.hecks_name}",
                                              request_for(command, params)).refusals
        refusals.each { |refusal| refuse(refusal) }
      rescue Hecks::Refused => e
        [refuse(e)]
      end

      # Records a refusal against the record: in `errors`, and by the dotted path of its form field.
      #
      # @param refusal [Hecks::Refused] what refused
      # @return [Hecks::Refused] the refusal
      def refuse(refusal)
        errors.add(refusal.attribute || :base, refusal.message)
        field_errors[dotted(refusal.path)] = refusal.message if refusal.path
        refusal
      end

      # @return [Hash{String => String}] the message for each form field a refusal was about, by the
      #   dotted path the form names it with; a field inside a value object the form shows as one
      #   input finds its message under the value object's name
      def field_errors
        @field_errors ||= Hash.new { |errors, path| errors.find { |name, _| path.start_with?("#{name}.") }&.last }
      end

      private

      def request_for(command, params)
        facts = Arguments.for(self.class, command, params)
        command.creates? ? { with: facts } : { to: id, with: facts }
      end

      def dotted(pointer) = pointer.delete_prefix("/").tr("/", ".")
    end
  end
end
