$(function() {
  "use strict";

  buildAssignConceptToAllMenu();

  function buildAssignConceptToAllMenu() {
    var $menu = $("#assign-concept-to-all-menu");
    $menu.html("");

    var options = {};

    $("#conceptual_exam_values_table input.conceptual-exam-value-select2").each(function() {
      var elements = $(this).data("elements") || [];

      _.each(elements, function(element) {
        if (_.isEmpty("" + element.id) || element.id === "empty") {
          return;
        }

        options[element.id] = element.text || element.name;
      });
    });

    _.each(options, function(text, id) {
      var $item = $("<li/>").append(
        $("<a/>")
          .attr("href", "#")
          .addClass("assign-concept-to-all-option")
          .attr("data-value-id", id)
          .text(text)
      );

      $menu.append($item);
    });
  }

  $(document).on("click", ".assign-concept-to-all-option", function(event) {
    event.preventDefault();

    var value_id = $(this).data("value-id");

    $("#conceptual_exam_values_table input.conceptual-exam-value-select2").each(function() {
      var $select = $(this);
      var $row = $select.closest("tr");

      if (!$row.is(":visible") || $select.prop("readonly")) {
        return;
      }

      var elements = $select.data("elements") || [];
      var valueIsValidForStudent = _.some(elements, function(element) {
        return "" + element.id === "" + value_id;
      });

      if (valueIsValidForStudent) {
        $select.select2("val", value_id).trigger("change");
      }
    });
  });
});
