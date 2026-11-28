module Hecks
  module Bluebook
    module DSL
      class HecksagonBuilder
        # What `attaches` does once it has read its arguments: loads the bluebook, records the
        # attachment, and gives the attached bluebook's undeclared policies the attachment's
        # `acts_as` role. Included into `HecksagonBuilder`.
        module Attaching
          private

          # Loads a bluebook the gem carries and records it as attached from the gem.
          def attach_gem(name, acts_as)
            require_relative "../../../framework_bluebooks"
            @attachments << Attachment.new(name: name.to_s, source: :gem, acts_as: acts_as)
            self.class.with_real_modules { Hecks::FrameworkBluebooks.attach!(name) }
            Hecks.current_registry&.mark_bounded(name.to_s)
            reactions_act_as(name.to_s, acts_as)
          end

          # Loads a vendored package and records it as attached from `vendor/`, under the bluebook
          # its bluebook declares: `"document"` attaches `Documents`.
          def attach_vendored(name, acts_as)
            declaration = Hecks::EmbryonautBluebook.load!(name)
            @attachments << Attachment.new(name: name.to_s, source: :vendor, declaration: declaration, acts_as: acts_as)
            Hecks.current_registry&.mark_bounded(declaration)
            reactions_act_as(declaration, acts_as)
          end

          # Gives the attached bluebook's policies that declare no `acts_as` the attachment's role.
          def reactions_act_as(bluebook_name, acts_as)
            return unless acts_as

            bluebook = Hecks.current_registry&.bluebook(bluebook_name) or return
            bluebook.policies.each { |policy| policy.act_as_by_default(acts_as.to_s) }
          end
        end
      end
    end
  end
end
