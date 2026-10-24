require_relative "../route_table"

module Hecks
  module Rails
    module Controller
      # Defines a controller's actions from its model's aggregate: `show`, one action per command
      # and one per query (named as `RouteTable.action_for` names it), each in the controller's own
      # `HecksActions` module.
      #
      # A creating command's action makes the record and redirects to it; any other command's
      # loads the record by `params[:id]`, runs the verb and redirects back to it; a query's
      # answers its rows as JSON. A refusal is not handled here: it rises to the controller's
      # `rescue_from`.
      module Actions
        module_function

        # Defines (or redefines) every action of `model` on `controller`.
        #
        # @param controller [Class] the controller including `Rails::Controller`
        # @param model [Class] the `Rails::Model` subclass it drives
        # @return [void]
        # @raise [Rails::NotBooted] if no domain is booted
        def define(controller, model)
          mod = actions_module(controller)
          aggregate = model.address.aggregate
          define_show(mod, model)
          aggregate.commands.each { |command| define_command(mod, model, command) }
          aggregate.queries.each { |query| define_query(mod, model, query) }
        end

        # Sets `@record` and the instance variable a view names the record by (`@account`).
        #
        # @param controller [ActionController::Base] the controller running an action
        # @param record [Rails::Model] the record the action loaded or tried to make
        # @return [Rails::Model] the record
        def assign(controller, record)
          controller.instance_variable_set(:@record, record)
          controller.instance_variable_set(:"@#{record.model_name.singular}", record)
          record
        end

        def actions_module(controller)
          if controller.const_defined?(:HecksActions, false)
            mod = controller.const_get(:HecksActions, false)
            mod.instance_methods(false).each { |method| mod.send(:remove_method, method) }
            return mod
          end

          controller.const_set(:HecksActions, Module.new).tap { |mod| controller.include(mod) }
        end

        def define_show(mod, model)
          mod.define_method(:show) do
            Actions.assign(self, model.find(params[:id]))
            template_exists?("show", _prefixes) ? render(:show) : render(json: @record.to_h)
          end
        end

        def define_command(mod, model, command)
          name = Naming.snake(command.hecks_name)
          mod.define_method(name) do
            Actions.assign(self, command.creates? ? model.new : model.find(params[:id]))
            Actions.assign(self, Actions.perform(model, @record, name, hecks_facts(command)))
            redirect_to @record, notice: Forms::Humanize.phrase(command.hecks_name)
          end
        end

        # Runs a verb: a creating one on the model class, any other on the loaded record.
        #
        # @param model [Class] the `Rails::Model` subclass
        # @param record [Rails::Model] the loaded record, or a shell for a creating verb
        # @param name [String] the verb's snake-case name
        # @param facts [Hash{Symbol => Object}] the verb's facts
        # @return [Rails::Model] the record the verb made or changed
        # @raise [Hecks::Refused] when the domain refuses the verb
        def perform(model, record, name, facts)
          record.persisted? ? record.public_send("#{name}!", facts) : model.public_send("#{name}!", facts)
        end

        def define_query(mod, model, query)
          mod.define_method(RouteTable.action_for(query)) do
            args = params.permit(*query.attributes.map { |attribute| attribute.name.to_s }).to_h.transform_keys(&:to_sym)
            render json: Hecks::Rails.domain.query(model.address, query, args)
          end
        end
      end
    end
  end
end
