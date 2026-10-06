# frozen_string_literal: true

require_relative "templates/membership"
require_relative "templates/session_strategy"
require_relative "templates/sso"
require_relative "templates/sso_tail"
require_relative "templates/users"

module Hecks
  module Projections
    module Site
      module AdminCms
        # The TypeScript text of the four files, with `__NAME__` placeholders that `AdminCms.fill`
        # replaces from the admin row. Each reads as the file a project would write by hand.
        module Templates
          module_function

          # @return [String] `auth/membership.ts`, before its placeholders are filled
          def membership = Membership::TEXT

          # @return [String] `auth/sessionStrategy.ts`, before its placeholders are filled
          def session_strategy = SessionStrategy::TEXT

          # @return [String] `endpoints/sso.ts`, before its placeholders are filled
          def sso = Sso::HEAD + Sso::TAIL

          # @return [String] `collections/Users.ts`, before its placeholders are filled
          def users = Users::TEXT
        end
      end
    end
  end
end
