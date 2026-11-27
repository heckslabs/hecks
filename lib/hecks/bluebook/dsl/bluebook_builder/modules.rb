module Hecks
  module Bluebook
    module DSL
      class BluebookBuilder
        # Groups a bluebook's aggregates in the modules it declares (ADR 0163). `domain_module
        # "Deliver" do … end` opens a block whose `aggregate` words are recorded under the module;
        # the module changes no aggregate, it names the task each one belongs to. Policies, read
        # models and sagas inside the block are the bluebook's own, as they are outside
        # it.
        module Modules
          # Opens the module `name` and evaluates its body; a module of that name that an earlier
          # file opened gains the aggregates this body declares.
          #
          # @param name [String] the module's own name, such as `"Deliver"`
          # @yield the module body: its vision, aggregates, policies, read models and process
          #   managers
          # @return [Array<Bluebook::Declaration::ModuleRow>] every membership declared so far
          # @raise [Bluebook::DSL::Malformed] if a module opens inside another, or holds no
          #   aggregate
          def domain_module(name, &)
            refuse_nested_module!(name)
            @open_module = name.to_s
            instance_eval(&) if block_given?
            refuse_empty_module!(@open_module)
            module_rows
          ensure
            @open_module = nil
          end

          private

          # One row per aggregate a module groups, in declaration order, each carrying its module's
          # vision (empty when the module names none).
          def module_rows
            module_members.map do |name, aggregate|
              Declaration::ModuleRow.new(name: name, vision: module_visions[name].to_s, aggregate: aggregate)
            end
          end

          # Each `[module, aggregate]` pair declared so far, in declaration order.
          def module_members = @module_members ||= []

          # Each module's vision by its name, for the modules that declared one.
          def module_visions = @module_visions ||= {}

          # Records an aggregate under the open module, if one is open.
          def note_in_open_module(name)
            module_members << [@open_module, name.to_s] if @open_module
          end

          # Records the open module's vision.
          def module_vision(value)
            held = module_visions[@open_module]
            raise Malformed, "domain_module #{@open_module.inspect} declares two visions" if held && held != value

            module_visions[@open_module] = value
          end

          # Refuses a bluebook-wide word written inside a module block.
          def bluebook_wide!(word)
            return unless @open_module

            raise Malformed, "#{word} describes the whole bluebook, so it cannot sit inside " \
                             "domain_module #{@open_module.inspect}"
          end

          def refuse_nested_module!(name)
            return unless @open_module

            raise Malformed, "domain_module #{name.inspect} sits inside domain_module " \
                             "#{@open_module.inspect}; modules do not nest"
          end

          def refuse_empty_module!(name)
            return if module_members.any? { |held, _| held == name }

            raise Malformed, "domain_module #{name.inspect} holds no aggregate"
          end
        end
      end
    end
  end
end
