class Issue < ActiveRecord::Base
  belongs_to :repository

  validates :title, presence: true
end
