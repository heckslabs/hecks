require "active_support/concern"
require "hecks/forms/command_form_renderer"
require_relative "model"
require_relative "controller/actions"

module Hecks
  module Rails
    # A controller over one model: `class AccountsController < ApplicationController; include
    # Hecks::Rails::Controller; end`.
    #
    # It gives the controller one named action per verb of the model's aggregate, plus `show`,
    # in a module of their own (`HecksActions`), so an app overrides one by name and calls
    # `super`. A refusal is rescued here once: it is added to the record's errors under the
    # refusal's attribute or `:base`, and the action answers 422 with the refusal's own words.
    #
    # Who is acting is `hecks_actor_id`; whether they may is the domain's Governance grant, which
    # the dispatch itself checks. An action with no actor runs as an anonymous caller, which any
    # verb that declares a role refuses.
    module Controller
      extend ActiveSupport::Concern

      included do
        rescue_from Hecks::Refused, with: :answer_hecks_refusal
        around_action :act_as_hecks_actor
        helper_method :hecks_record
        drives(controller_name.classify.safe_constantize) if controller_name.classify.safe_constantize
      end

      class_methods do
        # Names the model this controller drives and defines its actions. Called on include with
        # the model the controller's name implies; call it again to name another.
        #
        # @param model [Class] a `Rails::Model` subclass
        # @return [void]
        # @raise [Rails::NotBooted] if no domain is booted
        def drives(model)
          @hecks_model = model
          Actions.define(self, model)
        end

        # @return [Class, nil] the model this controller drives
        def hecks_model = @hecks_model || (superclass.respond_to?(:hecks_model) ? superclass.hecks_model : nil)
      end

      # Answers the record the current action loaded or tried to make.
      #
      # @return [Rails::Model, nil] the record; nil before an action set one
      def hecks_record = @record

      private

      # The actor's identity: the app's `hecks_actor_id` when it defines one (in this controller or
      # any it inherits from), else `current_user`'s, else nobody. The module defines no
      # `hecks_actor_id` of its own, so it never hides the one an `ApplicationController` defines.
      def acting_actor_id
        return hecks_actor_id if respond_to?(:hecks_actor_id, true)

        respond_to?(:current_user, true) ? Model::Availability.actor_id_of(current_user) : nil
      end

      # The role the actor claims: the app's `hecks_role` when it defines one, else none, so only a
      # Governance grant can satisfy a verb's role.
      def acting_role = respond_to?(:hecks_role, true) ? hecks_role.to_s : ""

      def act_as_hecks_actor(&)
        Hecks.as_caller(role: acting_role, actor_id: acting_actor_id, as_of: Time.now.to_i, &)
      end

      def answer_hecks_refusal(refusal)
        @record ||= self.class.hecks_model.new
        @record.errors.add(refusal.attribute || :base, refusal.message) unless @record.errors.any?
        Actions.assign(self, @record)
        render_hecks_refusal
      end

      def render_hecks_refusal
        return render(action_name, status: 422) if template_exists?(action_name, _prefixes)
        return render(:show, status: 422) if @record.persisted? && template_exists?("show", _prefixes)

        render plain: @record.errors.full_messages.join("\n"), status: 422
      end

      # The facts a verb's form posted, cast through the same field tree the form was drawn from.
      def hecks_facts(command)
        fields = Forms::CommandFormRenderer.fields_for(self.class.hecks_model.address.aggregate, command)
                                           .reject { |field| field.path == "to" }
        raw = params.permit(*Forms::Params.paths(fields)).to_h
        Forms::Params.extract(fields, raw)
      rescue ArgumentError, TypeError => e
        raise Hecks::Refused, "#{command.hecks_name} refused — #{e.message}"
      end
    end
  end
end
