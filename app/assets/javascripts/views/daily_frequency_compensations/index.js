$(function() {
  'use strict';

  $(document).on('click', '.reject-compensation-link', function(event) {
    event.preventDefault();

    let link = $(this);
    let reason = window.prompt(link.data('reject-prompt'));

    if (reason === null || reason.trim() === '') {
      return;
    }

    let form = $('<form>', { method: 'POST', action: link.attr('href') });
    form.append($('<input>', { type: 'hidden', name: '_method', value: 'patch' }));
    form.append($('<input>', { type: 'hidden', name: 'authenticity_token', value: $('meta[name="csrf-token"]').attr('content') }));
    form.append($('<input>', { type: 'hidden', name: 'rejection_reason', value: reason }));

    $('body').append(form);
    form.submit();
  });
});
