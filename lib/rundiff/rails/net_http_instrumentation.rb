module RunDiff
  module Rails
    module NetHttpInstrumentation
      EVENT_NAME = "request.net_http.rundiff"

      def request(request, body = nil, &block)
        ActiveSupport::Notifications.instrument(
          EVENT_NAME,
          method: request.method,
          host: address,
          port: port
        ) do
          super
        end
      end
    end
  end
end
