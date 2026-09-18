require "net/http"
require Rails.root.join("lib/rundiff/rails/net_http_instrumentation").to_s

Net::HTTP.prepend(RunDiff::Rails::NetHttpInstrumentation) unless Net::HTTP < RunDiff::Rails::NetHttpInstrumentation
