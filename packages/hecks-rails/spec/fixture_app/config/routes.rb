# The domain's verbs: a POST per command, a GET per query, and `show` per aggregate.
Rails.application.routes.draw do
  hecks_routes "banking"
end
