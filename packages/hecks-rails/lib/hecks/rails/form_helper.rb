require "hecks/forms/command_form_renderer"

module Hecks
  module Rails
    # `bluebook_form_for(@account.freeze_account)` in a view: a verb's form, drawn by
    # `Hecks::Forms` from the verb's IR command, so the fields are the ones the bluebook declares
    # and the controller's `hecks_facts` casts the post against the same field tree.
    #
    # The record a member verb acts on is the route's `:id`, so the form carries no identity
    # field. A refusal the record holds is shown beside the field it names, or above the form.
    module FormHelper
      # Renders the form that posts one verb.
      #
      # @param command [Bluebook::Command] the verb, as `record.freeze_account` or `Account.open`
      #   answers it
      # @param record [Rails::Model, nil] the record a member verb acts on; the controller's
      #   current record when not given
      # @param url [String, nil] where the form posts; the verb's derived route when not given
      # @return [ActiveSupport::SafeBuffer] the `<form>` element
      # @raise [ArgumentError] if no aggregate of the booted domain declares `command`
      def bluebook_form_for(command, record: hecks_form_record, url: nil)
        owner = Hecks::Rails.domain.owner_of(command) or
          raise ArgumentError, "no aggregate of the booted domain declares #{command.hecks_name}"
        fields = Forms::CommandFormRenderer.fields_for(owner.aggregate, command).reject { |field| field.path == "to" }
        form_tag(url || hecks_verb_path(owner, command, record), method: :post) do
          safe_join([hecks_base_errors(record), hecks_fields(owner, fields, record),
                     submit_tag(Forms::Humanize.phrase(command.hecks_name))])
        end
      end

      private

      def hecks_form_record = respond_to?(:hecks_record) ? hecks_record : nil

      def hecks_verb_path(owner, command, record)
        resource = Naming.snake(owner.aggregate.hecks_name).pluralize
        url_for(controller: "/#{resource}", action: Naming.snake(command.hecks_name),
                id: command.creates? ? nil : record&.to_param, only_path: true)
      end

      def hecks_fields(owner, fields, record)
        options = Forms::ReferenceOptions.collect(Hecks::Rails.domain.registry, owner.chapter, fields)
        held = request.request_parameters
        html = fields.map do |field|
          Forms::FieldRenderer.render(field, values: held, errors: hecks_field_errors(record), reference_options: options)
        end
        html.join.html_safe
      end

      def hecks_field_errors(record)
        return {} unless record

        record.errors.to_hash.except(:base).to_h { |attribute, messages| [attribute.to_s, messages.first] }
      end

      def hecks_base_errors(record)
        messages = record ? record.errors[:base] : []
        return "".html_safe if messages.empty?

        content_tag(:div, safe_join(messages.map { |message| content_tag(:p, message) }), class: "error-banner", role: "alert")
      end
    end
  end
end
