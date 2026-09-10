class RepositoriesController < ApplicationController
  def index
    @repositories = Repository.order(updated_at: :desc)
  end

  def show
    @repository = Repository.includes(:issues, :commits).find(params[:id])
    @issue = @repository.issues.build
    @commit = @repository.commits.build
  end
end
