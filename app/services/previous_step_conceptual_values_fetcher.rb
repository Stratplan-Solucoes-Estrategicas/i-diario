class PreviousStepConceptualValuesFetcher
  def initialize(classroom, student, current_step)
    @classroom = classroom
    @student = student
    @current_step = current_step
  end

  def fetch
    return {} if previous_step.blank?

    values = {}

    conceptual_exam_values.ordered.each do |conceptual_exam_value|
      next if conceptual_exam_value.value.blank?

      values["#{conceptual_exam_value.discipline_id}"] = conceptual_exam_value.value
    end

    values
  end

  private

  def conceptual_exam_values
    ConceptualExamValue.joins(:conceptual_exam)
      .merge(
        ConceptualExam.where(student_id: @student.id)
                      .by_classroom(@classroom.id)
                      .by_step_id(@classroom, previous_step.id)
      )
  end

  def previous_step
    @previous_step ||= StepsFetcher.new(@classroom).old_steps(@current_step.step_number).last
  end
end
