ZendeskPusher::Application.routes.draw do
  resources :jobs, only: [] do
    member { get :stream }
  end

  resources :projects, only: [:edit, :show]

  get '/auth/:provider/callback', to: 'sessions#create'
  get '/auth/failure', to: 'sessions#failure'

  get '/login', to: 'sessions#new'
  get '/logout', to: 'sessions#destroy'

  root to: 'projects#index'
end
