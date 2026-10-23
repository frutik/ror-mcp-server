Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Same paths as the Django reference app (spec/parity/django_app/refproject/urls.py).
  # Mounts match by prefix in order, so the longer path goes first.
  mount RorMcp.endpoint(:analytics), at: "/mcp/analytics"
  mount RorMcp::Engine, at: "/mcp"
end
