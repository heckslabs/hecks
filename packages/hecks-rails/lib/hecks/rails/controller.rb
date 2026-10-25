module Hecks
  module Rails
    # A controller over a model. `AccountsController` joins the domain by its name, with nothing
    # to include or declare; who acts is the app's `current_user` (see `Actor`).
    #
    # `hecks_model` defines `show` and an action per command in a module the controller includes,
    # so redefining an action by name and calling `super` keeps the generated body. Every dispatch
    # runs as the caller `hecks_actor` names, so Governance grants decide who may do what; a request
    # with no actor is anonymous and refused by every role-gated command. A refusal lands in the
    # record's `errors` and is answered with the status its kind calls for.
    module Controller
      extend ActiveSupport::Concern

      ANONYMOUS = "anonymous".freeze

      # How a refusal's kind is answered; any other kind is an unprocessable request.
      STATUSES = { not_found: :not_found, unauthorized: :forbidden }.freeze

      # The values of `dry_run` / `X-Dry-Run` that ask for a validation instead of the command.
      DRY_RUN_FLAGS = %w[1 true].freeze

      included do
        around_action :bind_hecks_caller
        rescue_from Hecks::Refused, with: :render_refusal
        inferred = Controller.model_for(self)
        hecks_model(inferred) if inferred
      end

      # @param klass [Class] a controller class
      # @return [Class, nil] the model its name points at (`AccountsController` -> `Account`), if
      #   the domain has one
      def self.model_for(klass)
        return unless Booted.booted?

        model = klass.name.to_s.delete_suffix("Controller").singularize.safe_constantize
        model if model.is_a?(Class) && model < Hecks::Rails::Model
      end

      # Mixed into every controller class so one whose name points at a model joins the domain with
      # no line of its own.
      module Inheritance
        # @param subclass [Class] the controller class being defined
        # @return [void]
        def inherited(subclass)
          super
          subclass.include(Controller) if Controller.model_for(subclass)
        end
      end

      class_methods do
        # Defines `show` and an action per command of the model's aggregate.
        #
        # @param model [Class] a `Hecks::Rails::Model` subclass
        # @return [void]
        def hecks_model(model = nil)
          return @hecks_model unless model

          @hecks_model = model
          include Actions.build(model)
        end
      end

      # The actor behind the request. Override it to name who is signed in.
      #
      # @return [Hash{Symbol => String}, nil] `{ actor_id:, role: }` (the role is informational),
      #   or nil for an anonymous request
      def hecks_actor = Hecks::Rails.actor_for(self)

      private

      def model = self.class.hecks_model

      def bind_hecks_caller(&)
        actor = hecks_actor
        return Hecks.as_caller(role: ANONYMOUS, &) unless actor

        Hecks.as_caller(role: actor.fetch(:role, "").to_s, actor_id: actor.fetch(:actor_id), &)
      end

      def show_record
        @record = model.find(params[:id])
        respond_to do |format|
          format.html { render plain: @record.inspect }
          format.json { render json: @record.to_h }
        end
      end

      def perform(command, action)
        @record = command.creates? ? model.unsaved : model.find(params[:id])
        return render_validation(action) if dry_run_requested?

        arguments = Arguments.for(model, command, params)
        target = command.creates? ? model : @record
        redirect_to target.public_send("#{action}!", **arguments)
      end

      # Whether the request asks to be checked, not carried out: `?dry_run=1` or `X-Dry-Run: 1`.
      def dry_run_requested?
        DRY_RUN_FLAGS.include?(params[:dry_run].to_s) || DRY_RUN_FLAGS.include?(request.headers["X-Dry-Run"].to_s)
      end

      # Answers every reason the command would be refused, as the domain gives them, with 200
      # whether or not it would be.
      def render_validation(action)
        refusals = @record.validate_command(action, params)
        render json: { ok: refusals.empty?, refusals: refusals.map(&:to_h) }
      end

      def render_refusal(refusal)
        @record ||= model.unsaved
        @record.refuse(refusal)
        status = STATUSES.fetch(refusal.kind, :unprocessable_entity)
        respond_to do |format|
          format.html { render_html_refusal(status) }
          format.json { render json: { errors: @record.errors.to_hash }, status: status }
        end
      end

      def render_html_refusal(status)
        return render(action_name, status: status) if lookup_context.exists?(action_name, _prefixes)

        render plain: @record.errors.full_messages.to_sentence, status: status
      end

      # The module a controller includes: one real method per command, so a subclass redefines one
      # by name and reaches the generated body with `super`.
      module Actions
        # @param model [Class] a `Hecks::Rails::Model` subclass
        # @return [Module] defining `show` and an action per command
        def self.build(model)
          Module.new do
            define_method(:show) { show_record }
            model.door.ir.commands.each do |command|
              action = Naming.snake(command.hecks_name).to_s
              define_method(action) { perform(command, action) }
            end
          end
        end
      end
    end
  end
end
