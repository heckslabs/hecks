module Hecks
  module Bluebook
    module DSL
      class HecksagonBuilder
        # The per-thread state of the hecksagon build in progress, and the shadowing of `Hecks`'s
        # real modules that lets the Hecks chapter spell its aggregates `Hecks::Operation`.
        # Extended onto `HecksagonBuilder`.
        module ChapterScope
          # The bind collector of the build running on this thread; thread-local, so a build
          # on another thread never sees it.
          #
          # @return [Array, nil] the binds the running build collects into
          def collector = Thread.current.thread_variable_get(:hecks_hecksagon_collector)

          # @param value [Array, nil] the binds the running build collects into
          def collector=(value)
            Thread.current.thread_variable_set(:hecks_hecksagon_collector, value)
          end

          # @return [String, nil] the name of the chapter whose hecksagon is being built
          def building = Thread.current.thread_variable_get(:hecks_hecksagon_building)

          # @param value [String, nil] the name of the chapter whose hecksagon is being built
          def building=(value)
            Thread.current.thread_variable_set(:hecks_hecksagon_building, value)
          end

          # @return [Hash, nil] the modules this thread's build has taken off `Hecks`
          def hidden_modules = Thread.current.thread_variable_get(:hecks_hecksagon_hidden)

          # @param value [Hash, nil] the modules this thread's build has taken off `Hecks`
          def hidden_modules=(value)
            Thread.current.thread_variable_set(:hecks_hecksagon_hidden, value)
          end

          # Takes off `Hecks` each real module a chapter aggregate shares its name with, so the
          # name reaches `ChapterConstants#const_missing`. Only the chapter named Hecks has this
          # collision; a nested build of it leaves the outer build's shadows in place.
          #
          # @param domain [String, Symbol] the chapter whose hecksagon is being built
          # @return [Hash{Symbol => Object}] what was taken off, by name: the module, or the
          #   autoload path when the constant had not loaded yet
          def shadowed(domain)
            return {} unless domain.to_s == "Hecks"

            chapter_aggregate_names.select { |name| Hecks.const_defined?(name, false) }.to_h do |name|
              pending = Hecks.autoload?(name)
              held    = pending ? [:autoload, pending] : [:module, Hecks.const_get(name, false)]
              Hecks.send(:remove_const, name)
              [name, held]
            end
          end

          # Runs the block with every module the running build shadowed back on `Hecks`, and a
          # missing `Hecks::X` an ordinary `NameError`, then shadows them again. A chapter loaded
          # from inside the hecksagon block is ordinary code, not the hecksagon's own vocabulary.
          # A no-op when nothing is shadowed.
          #
          # @yield the code that must see `Hecks`'s real modules
          # @return [Object] the block's result
          def with_real_modules
            hidden = hidden_modules
            return yield if hidden.nil? || hidden.empty?

            name = building
            restore_shadowed(hidden)
            self.building = nil
            begin
              yield
            ensure
              reshadow(hidden, name)
            end
          end

          # Puts back what `shadowed` took off.
          #
          # @param hidden [Hash{Symbol => Array}] `shadowed`'s answer
          # @return [void]
          def restore_shadowed(hidden)
            hidden.each do |name, (kind, held)|
              Hecks.send(:remove_const, name) if Hecks.const_defined?(name, false)
              kind == :autoload ? Hecks.autoload(name, held) : Hecks.const_set(name, held)
            end
          end

          # Runs the block with this thread's collector, chapter name and shadowed modules set for
          # building `domain`'s hecksagon, restoring the outer build's state afterwards.
          #
          # @param domain [String, Symbol] the chapter whose hecksagon is being built
          # @param binds [Array] the binds the build collects into
          # @yield the build
          # @return [Object] the block's result
          def scoped_to(domain, binds)
            saved = enter_scope(domain, binds)
            begin
              yield
            ensure
              leave_scope(saved)
            end
          end

          private

          def chapter_aggregate_names
            chapter = Hecks.current_registry&.bluebook("Hecks")
            chapter ? chapter.aggregates.map { |aggregate| aggregate.hecks_name.to_sym } : []
          end

          def reshadow(hidden, name)
            self.building = name
            hidden.replace(shadowed(name))
          end

          def enter_scope(domain, binds)
            saved = { collector: collector, building: building, hidden_modules: hidden_modules }
            self.collector = binds
            self.building  = domain.to_s
            hidden = saved[:building] == "Hecks" ? {} : shadowed(domain)
            self.hidden_modules = hidden.empty? ? saved[:hidden_modules] : hidden
            saved.merge(hidden: hidden)
          end

          def leave_scope(saved)
            restore_shadowed(saved[:hidden])
            self.hidden_modules = saved[:hidden_modules]
            self.collector      = saved[:collector]
            self.building       = saved[:building]
          end
        end
      end
    end
  end
end
