class IssuesController < ApplicationController
  def create
    repository = Repository.find(params[:repository_id])
    repository.issues.create!(issue_params)
    redirect_to repository_path(repository), notice: "Issue opened"
  rescue ActiveRecord::RecordInvalid => error
    redirect_to repository_path(repository), alert: error.record.errors.full_messages.to_sentence
  end

  private

  def issue_params
    params.require(:issue).permit(:title, :body)
  end
end
