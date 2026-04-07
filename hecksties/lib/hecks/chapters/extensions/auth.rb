# = Hecks::Chapters::Extensions::AuthChapter
#
# Self-describing sub-chapter for auth extension internals:
# screen routes (login/signup/logout), session store, and
# template binding for auth ERB views.
#
#   Hecks::Chapters::Extensions::AuthChapter.define(builder)
#
module Hecks
  module Chapters
    module Extensions
      # Hecks::Chapters::Extensions::AuthChapter
      #
      # Bluebook sub-chapter for auth extension internals: screen routes, session store, and template binding.
      #
      module AuthChapter
        def self.define(b)
          b.aggregate "ScreenRoutes", "Login, signup, and logout HTTP route handlers for auth screens" do
            command("HandleAuthRoute") { attribute :path, String; attribute :method, String }
          end

          b.aggregate "SessionStore", "In-memory credential store with cookie-based session management" do
            command("SetSession") { attribute :email, String; attribute :role, String }
            command("RestoreSession") { attribute :cookie, String }
          end

          b.aggregate "TemplateBinding", "Minimal binding for auth screen ERB templates" do
            command("Bind") { attribute :template_name, String }
          end
        end
      end
    end
  end
end
