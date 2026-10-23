# The pizza shop on the web: both driving adapters in front of one booted Pizzas.
#
#   PAYMENT_WEBHOOK_SECRET=whsec_local bundle exec rackup examples/pizzas/config.ru -p 9292
#
# `/` is the forms app (the Json driving adapter `pizzas.hecksagon` admits): a page per command,
# so a chef creates a pizza and adds toppings and a customer buys one. `/webhooks/payments` is
# where the payment processor reports a payment, told to the domain through
# `Order.PaymentGateway.Receive`. A development server: no sign-in and no CSRF protection.
require "hecks"
require "hecks/forms"
require_relative "adapters/payment_webhook"

runtime = Hecks.boot(__dir__)
Hecks::Forms.configure("PizzaShop") { expose "Pizzas" }

map "/webhooks/payments" do
  run PizzaShop::PaymentWebhook.new(runtime: runtime, secret: ENV.fetch("PAYMENT_WEBHOOK_SECRET"))
end

map "/" do
  run Hecks::Forms::App.for(registry: runtime.registry, app_name: "PizzaShop")
end
