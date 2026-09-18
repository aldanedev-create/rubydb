# frozen_string_literal: true

class Customer < ApplicationRecord
  has_many :orders, dependent: :restrict_with_exception

  validates :name, :email, presence: true
  validates :email, uniqueness: true
end
