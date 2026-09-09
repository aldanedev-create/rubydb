# frozen_string_literal: true

class TasksController < ApplicationController
  def index
    @tasks = Task.order(created_at: :desc)
    @task = Task.new
  end

  def create
    Task.create!(task_params)
    redirect_to root_path, notice: "Task created"
  rescue ActiveRecord::RecordInvalid => error
    @tasks = Task.order(created_at: :desc)
    @task = error.record
    render :index, status: :unprocessable_entity
  end

  private

  def task_params
    params.require(:task).permit(:title)
  end
end
