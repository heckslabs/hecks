module Hecks
  module Rails
    # `command_form_for`, for a view:
    #
    #     <%= command_form_for @account, :freeze_account, url: freeze_path(@account) %>
    #     <%= command_form_for Account, :open_account, url: open_account_path %>
    #
    # The fields come from the command's declaration, through the `Hecks::Forms` layer the
    # standalone forms app renders, so a field exists when the command takes it. Names are the
    # dotted paths `Hecks::Forms::Params` reads back (`balance.cents`).
    module FormHelper
      # @param subject [Hecks::Rails::Model, Class, Symbol, String] a record, or the model for a
      #   creating command, as its class or its name such as `:account`
      # @param verb [Symbol] the command's bare verb
      # @param url [String] where the form posts
      # @param values [Hash{String => Object}] the values to show, by dotted path
      # @return [ActiveSupport::SafeBuffer] the form
      def command_form_for(subject, verb, url:, values: {})
        fields = command_fields(subject, verb)
        inputs = fields.map { |field| Hecks::Forms::FieldRenderer.render(field, values: values) }.join
        content_tag(:form, safe_join([command_token(url), inputs.html_safe, submit_tag(verb.to_s.humanize)]),
                    action: url, method: "post")
      end

      private

      def command_fields(subject, verb)
        subject = subject.to_s.camelize.constantize if subject.is_a?(Symbol) || subject.is_a?(String)
        model = subject.is_a?(Class) ? subject : subject.class
        subject.public_send(verb).attributes.map do |attribute|
          Hecks::Forms::FieldShape.resolve(attribute, aggregate: model.door.ir)
        end
      end

      def command_token(url)
        respond_to?(:token_tag) ? token_tag(nil, form_options: { action: url, method: "post" }) : "".html_safe
      end
    end
  end
end

ActiveSupport.on_load(:action_view) { include Hecks::Rails::FormHelper }
