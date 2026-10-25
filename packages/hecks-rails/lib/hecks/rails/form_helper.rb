module Hecks
  module Rails
    # `command_form_for`, for a view:
    #
    #     <%= command_form_for @account, :freeze_account, url: freeze_path(@account) %>
    #     <%= command_form_for Account, :open_account, url: open_account_path %>
    #
    # The fields come from the command's declaration, through the `Hecks::Forms` layer the
    # standalone forms app renders, so a field exists when the command takes it. Names are the
    # dotted paths `Hecks::Forms::Params` reads back (`balance.cents`). After a refusal the form
    # shows the submitted values and each reason beside its field, a reference field lists the
    # records it can point at, and the command's JSON Schema rides along for a script to check.
    module FormHelper
      # @param subject [Hecks::Rails::Model, Class, Symbol, String] a record, or the model for a
      #   creating command, as its class or its name such as `:account`
      # @param verb [Symbol] the command's bare verb
      # @param url [String] where the form posts
      # @param values [Hash{String => Object}, nil] the values to show, by dotted path; the
      #   request's own parameters when omitted
      # @return [ActiveSupport::SafeBuffer] the form
      def command_form_for(subject, verb, url:, values: nil)
        subject = command_subject(subject)
        fields = command_fields(subject, verb)
        inputs = fields.map { |field| command_input(field, subject, fields, values) }.join
        content_tag(:form, safe_join([command_token(url), inputs.html_safe, command_schema(subject, verb),
                                      submit_tag(verb.to_s.humanize)]), action: url, method: "post")
      end

      private

      def command_subject(subject)
        subject.is_a?(Symbol) || subject.is_a?(String) ? subject.to_s.camelize.constantize : subject
      end

      def command_model(subject) = subject.is_a?(Class) ? subject : subject.class

      def command_fields(subject, verb)
        model = command_model(subject)
        subject.public_send(verb).attributes.map do |attribute|
          Hecks::Forms::FieldShape.resolve(attribute, aggregate: model.door.ir)
        end
      end

      def command_input(field, subject, fields, values)
        Hecks::Forms::FieldRenderer.render(field, values: values || submitted_values, errors: refused_fields(subject),
                                                  reference_options: command_references(subject, fields))
      end

      # The messages for the form's fields: the record's own, or for a creating command (shown from
      # the model) those of the unsaved record the controller refused.
      def refused_fields(subject)
        source = subject.is_a?(Class) ? @record : subject
        source.field_errors if source.is_a?(command_model(subject))
      end

      def command_references(subject, fields)
        domain = command_model(subject).door.fqn.split("::").first
        Hecks::Forms::ReferenceOptions.collect(Booted.registry, domain, fields)
      end

      # The request's own parameters, flat, so a refused form comes back as it was filled in.
      def submitted_values
        respond_to?(:params) && params ? Arguments.flat(params) : {}
      end

      # The command's JSON Schema in the page, for a script that checks input before it is sent.
      def command_schema(subject, verb)
        content_tag(:script, JSON.generate(schema_document(subject, verb)).html_safe, type: "application/schema+json")
      end

      def schema_document(subject, verb)
        aggregate = command_model(subject).door.ir
        command = subject.public_send(verb)
        chapter = Booted.chapter(command_model(subject).door.fqn.split("::").first)
        Hecks::Projections::CommandSchema.document(chapter, aggregate, "#{aggregate.hecks_name}/#{command.hecks_name}", command)
      end

      def command_token(url)
        respond_to?(:token_tag) ? token_tag(nil, form_options: { action: url, method: "post" }) : "".html_safe
      end
    end
  end
end

ActiveSupport.on_load(:action_view) { include Hecks::Rails::FormHelper }
