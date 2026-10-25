# Joins the domain by its name, with the same header-read sign-in as the accounts. It checks the
# forgery token like an app that loads Rails' defaults does, which applies when protection is on.
class NotesController < ActionController::Base
  protect_from_forgery with: :exception

  def current_user
    id = request.headers["X-Actor"]
    id && AccountsController::Person.new(id)
  end
end
