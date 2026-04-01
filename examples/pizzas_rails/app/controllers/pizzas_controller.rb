# PizzasController
#
# Scaffold-style CRUD controller for the Pizza aggregate, backed by the
# Hecks in-memory adapter. Provides index, show, new, create, edit,
# update, and destroy actions for smoke-testing the Rails example app.
#
# Usage (routes):
#   resources :pizzas
#   root to: "pizzas#index"
#
class PizzasController < ApplicationController
  skip_before_action :allow_browser, raise: false
  before_action :set_pizza, only: %i[show edit update destroy]

  def index
    @pizzas = Pizza.all
  end

  def show; end

  def new
    @pizza = Pizza.new(name: "", description: "")
  end

  def create
    @pizza = Pizza.new(**pizza_params)
    if @pizza.valid?
      cmd = Pizza.create(**pizza_params)
      redirect_to pizza_path(cmd.aggregate.id)
    else
      @errors = @pizza.errors.full_messages
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    @pizza = Pizza.new(id: @pizza.id, **pizza_params)
    if @pizza.valid?
      pizza_repo.save(@pizza)
      redirect_to pizza_path(@pizza.id)
    else
      @errors = @pizza.errors.full_messages
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    Pizza.delete(@pizza.id)
    redirect_to pizzas_path
  end

  private

  def set_pizza
    @pizza = Pizza.find(params[:id])
    head :not_found unless @pizza
  end

  def pizza_params
    p = params.fetch(:pizza, {}).permit(:name, :description)
    { name: p[:name].to_s, description: p[:description].to_s }
  end

  def pizza_repo
    Pizza::Commands::CreatePizza.repository
  end
end
