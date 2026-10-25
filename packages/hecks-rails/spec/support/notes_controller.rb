# Joins the domain by its name, with the same header-read sign-in as the accounts.
class NotesController < ActionController::Base
  def current_user
    id = request.headers["X-Actor"]
    id && AccountsController::Person.new(id)
  end
end
