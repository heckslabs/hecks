# HecksTemplating::SmokeTest::EndpointTests
#
# Tests domain views, workflows, and services over HTTP.
# Views are tested with GET, workflows and services with POST.
#
#   test_views(results)
#   test_workflows(results)
#   test_services(results)
#
module HecksTemplating
  class SmokeTest
    module EndpointTests
      private

      def test_views(results)
        @domain.views.each do |view|
          view_snake = underscore(view.name)
          path = "/_views/#{view_snake}"
          results << check_get(path, "view #{view.name}")
        end
      end

      def test_workflows(results)
        @domain.workflows.each do |wf|
          wf_snake = underscore(wf.name)
          path = "/_workflows/#{wf_snake}"
          # Workflows need POST with attributes
          first_cmd = find_workflow_first_cmd(wf)
          data = first_cmd ? build_form_data(first_cmd) : {}
          results << check_post(path, data, "workflow #{wf.name}")
        end
      end

      def test_services(results)
        @domain.services.each do |svc|
          svc_snake = underscore(svc.name)
          path = "/_services/#{svc_snake}"
          data = svc.respond_to?(:attributes) ? build_service_data(svc) : {}
          results << check_post(path, data, "service #{svc.name}")
        end
      end
    end
  end
end
