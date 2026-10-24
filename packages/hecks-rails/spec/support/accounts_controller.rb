# Names the signed-in actor from a header, standing in for an app's own authentication.
class AccountsController < ActionController::Base
  include Hecks::Rails::Controller

  hecks_model Account

  def hecks_actor
    actor = request.headers["X-Actor"]
    actor && { actor_id: actor }
  end
end
