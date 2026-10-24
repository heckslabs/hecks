# The fixture has no sign-in: the request names its actor in the `X-Actor` header, and the
# domain's Governance grants decide what that actor may do.
class ApplicationController < ActionController::Base
  private

  def hecks_actor_id = request.headers["X-Actor"].presence
end
