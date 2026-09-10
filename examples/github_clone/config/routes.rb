RubyDBGitHubClone::Application.routes.draw do
  root "repositories#index"
  resources :repositories, only: %i[index show] do
    resources :issues, only: :create
    resources :commits, only: :create
  end
end
