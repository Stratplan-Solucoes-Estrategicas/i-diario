$(function() {
  'use strict';
  const flashMessages = new FlashMessages();

  $('#conceptual_exam_classroom_id').on('change', function () {
    flashMessages.pop('');
    $('#conceptual_exam_step_id').select2('val', '');

    populateSteps();
  });

  $('#conceptual_exam_discipline_id').on('change', function () {
    flashMessages.pop('');
    $('#conceptual_exam_descriptor_id').select2('val', '');

    populateDescriptors();
  });

  function populateSteps() {
    let classroom_id = $('#conceptual_exam_classroom_id').select2('val');

    if (!_.isEmpty(classroom_id)) {
      $.ajax({
        url: Routes.get_steps_conceptual_exams_in_batchs_pt_br_path({
          classroom_id: classroom_id,
          format: 'json'
        }),
        success: handleFetchStepsSuccess,
        error: handleFetchStepsError
      });
    }
  }

  function handleFetchStepsSuccess(data) {
    let steps = _.map(data.conceptual_exams_in_batchs, function(step) {
      return { id: step.table.id, name: step.table.name, text: step.table.text };
    });

    $('#conceptual_exam_step_id').select2({ data: steps })
  }

  function handleFetchStepsError() {
    flashMessages.error('Ocorreu um erro ao buscar as etapas da turma.');
  }

  function populateDescriptors() {
    let discipline_id = $('#conceptual_exam_discipline_id').select2('val');

    if (!_.isEmpty(discipline_id)) {
      $.ajax({
        url: Routes.get_descriptors_conceptual_exams_in_batchs_pt_br_path({
          discipline_id: discipline_id,
          format: 'json'
        }),
        success: handleFetchDescriptorsSuccess,
        error: handleFetchDescriptorsError
      });
    }
  }

  function handleFetchDescriptorsSuccess(data) {
    let descriptors = _.map(data.conceptual_exams_in_batchs, function(descriptor) {
      return { id: descriptor.table.id, name: descriptor.table.name, text: descriptor.table.text };
    });

    $('#conceptual_exam_descriptor_id').select2({ data: descriptors });

    if (descriptors.length === 1) {
      $('#conceptual_exam_descriptor_id').select2('val', descriptors[0].id);
    }
  }

  function handleFetchDescriptorsError() {
    flashMessages.error('Ocorreu um erro ao buscar os objetivos de aprendizagem do componente curricular.');
  }
});
