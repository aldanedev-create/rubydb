# frozen_string_literal: true

Rails.application.routes.draw do
  root "catalog#index"
  get "/products", to: "catalog#index"
  resources :orders, only: :create
end
