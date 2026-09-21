# frozen_string_literal: true

class DailyFrequencyCompensation < ApplicationRecord
  audited

  belongs_to :teacher
  belongs_to :unity
  belongs_to :classroom
  belongs_to :discipline, optional: true
  belongs_to :approved_by, class_name: 'User', optional: true

  has_many :daily_frequencies, dependent: :nullify

  has_enumeration_for :status,
                      with: DailyFrequencyCompensationStatus,
                      create_helpers: true,
                      create_scopes: true

  validates :compensation_date, :reason, presence: true
  validates :lesson_numbers, presence: true
  validate :compensation_date_must_be_less_than_or_equal_to_today

  def lesson_numbers=(value)
    value = value.is_a?(Array) ? value : [value]

    super(value.map(&:to_s).select { |v| v =~ /\A\d+\z/ }.map(&:to_i).sort.uniq)
  end

  scope :by_teacher_id, ->(teacher_id) { where(teacher_id: teacher_id) }
  scope :by_classroom_id, ->(classroom_id) { where(classroom_id: classroom_id) }
  scope :by_unity, ->(unity) { where(unity: unity) }
  scope :ordered, -> { order(created_at: :desc) }

  def approve!(pedagogo)
    update!(
      status: DailyFrequencyCompensationStatus::APPROVED,
      approved_by: pedagogo,
      approved_at: Time.zone.now
    )
  end

  def reject!(pedagogo, motivo)
    update!(
      status: DailyFrequencyCompensationStatus::REJECTED,
      approved_by: pedagogo,
      approved_at: Time.zone.now,
      rejection_reason: motivo
    )
  end

  private

  def compensation_date_must_be_less_than_or_equal_to_today
    return if compensation_date.blank?

    if compensation_date > Time.zone.today
      errors.add(:compensation_date, :must_be_less_than_or_equal_to_today)
    end
  end
end
