module Hecks
  module Rails
    # The pages a controller answers with. An app's own `orders/index` view wins; without one the
    # gem's page for the aggregate is rendered, so a controller with no view files still has a
    # list, a record page and a form for every command.
    module Rendering
      private

      def index_records
        @records = model.all
        respond_to do |format|
          format.html { render_page(:index) }
          format.json { render json: @records.map(&:to_h) }
        end
      end

      def render_page(page, **)
        return render(page, **) if lookup_context.exists?(page.to_s, _prefixes)

        render("hecks/rails/#{page}", **)
      end

      def render_html_refusal(status)
        return render(action_name, status: status) if lookup_context.exists?(action_name, _prefixes)

        render_page(@record.persisted? ? :show : :index, status: status)
      end
    end
  end
end
