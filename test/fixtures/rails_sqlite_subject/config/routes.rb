Rails.application.routes.draw do
  post "/__rundiff/demo/behavior" => "demo/behavior#create"
end
