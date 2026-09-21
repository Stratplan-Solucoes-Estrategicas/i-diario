class DailyFrequencyCompensationsController < ApplicationController
  before_action :require_current_classroom, only: %i[new create]
  before_action :require_current_teacher, only: %i[new create]
  before_action :authorize_request, only: %i[new create]
  before_action :authorize_approval, only: %i[index approve reject]
  before_action :set_daily_frequency_compensation, only: %i[approve reject]

  def index
    @daily_frequency_compensations = DailyFrequencyCompensation.includes(:teacher, :classroom, :discipline)
                                                                .by_unity(current_unity)
                                                                .ordered

    status = params[:status].to_s
    if DailyFrequencyCompensationStatus.list.include?(status)
      @daily_frequency_compensations = @daily_frequency_compensations.where(status: status)
    else
      @daily_frequency_compensations = @daily_frequency_compensations.pending
    end
  end

  def new
    @daily_frequency_compensation = DailyFrequencyCompensation.new(
      unity_id: current_unity.id,
      classroom_id: current_user_classroom.id,
      discipline_id: current_user_discipline&.id
    )

    set_lesson_numbers
  end

  def create
    @daily_frequency_compensation = DailyFrequencyCompensation.new(resource_params)
    @daily_frequency_compensation.teacher_id = current_teacher_id
    @daily_frequency_compensation.status = DailyFrequencyCompensationStatus::PENDING

    if @daily_frequency_compensation.save
      flash[:success] = t('.success')
      redirect_to new_daily_frequency_compensation_path
    else
      set_lesson_numbers
      flash.now[:error] = t('.error')
      render :new
    end
  end

  def approve
    @daily_frequency_compensation.approve!(current_user)

    flash[:success] = t('.success')
    redirect_to daily_frequency_compensations_path
  end

  def reject
    @daily_frequency_compensation.reject!(current_user, params[:rejection_reason])

    flash[:success] = t('.success')
    redirect_to daily_frequency_compensations_path
  end

  private

  def authorize_request
    return if current_user.can_change?(:daily_frequency_compensations)

    flash[:alert] = t('errors.general.require_permission')
    redirect_to root_path
  end

  def authorize_approval
    return if current_user.can_change?(:daily_frequency_compensations_approval)

    flash[:alert] = t('errors.general.require_permission')
    redirect_to root_path
  end

  def set_daily_frequency_compensation
    @daily_frequency_compensation = DailyFrequencyCompensation.find(params[:id])
  end

  def set_lesson_numbers
    @lesson_numbers = (1..current_user_classroom.number_of_classes).to_a
  end

  def resource_params
    params.require(:daily_frequency_compensation).permit(
      :unity_id,
      :classroom_id,
      :discipline_id,
      :compensation_date,
      :reason,
      lesson_numbers: []
    )
  end
end
