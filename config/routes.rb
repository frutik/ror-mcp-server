# frozen_string_literal: true

# Routes of RorMcp::Engine: the default server at the engine's mount point.
RorMcp::Engine.routes.draw do
  mount RorMcp.endpoint(:default), at: "/"
end
