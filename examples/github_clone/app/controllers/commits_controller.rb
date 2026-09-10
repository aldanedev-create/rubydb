class CommitsController < ApplicationController
  def create
    repository = Repository.find(params[:repository_id])
    repository.commits.create!(commit_params)
    redirect_to repository_path(repository), notice: "Commit recorded"
  rescue ActiveRecord::RecordInvalid => error
    redirect_to repository_path(repository), alert: error.record.errors.full_messages.to_sentence
  end

  private

  def commit_params
    params.require(:commit).permit(:sha, :message, :author)
  end
end
