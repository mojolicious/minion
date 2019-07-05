
function checkAll() {
  $('.checkall').click(function () {
    var name  = $(this).data('check');
    var input = $('input[type=checkbox][name=' + name + ']');
    input.prop('checked', $(this).prop('checked'));
  });
}

function humanTime() {
  $('.from-now').each(function () {
    var date = $(this);
    date.text(moment(date.text() * 1000).fromNow());
  });
  $('.duration').each(function () {
    var date = $(this);
    console.log(date.text() * 1000);
    date.text(moment.duration(date.text() * 1000).humanize());
  });
 }

function pageStats(data) {}

function pollStats(url) {
  $.get(url).done(function (data) {
    $('.minion-stats-active-jobs').html(data.active_jobs);
    $('.minion-stats-active-locks').html(data.active_locks);
    $('.minion-stats-failed-jobs').html(data.failed_jobs);
    $('.minion-stats-finished-jobs').html(data.finished_jobs);
    $('.minion-stats-inactive-jobs').html(data.inactive_jobs);
    $('.minion-stats-workers').html(data.active_workers + data.inactive_workers);
    pageStats(data);
    setTimeout(function () { pollStats(url) }, 3000);
  }).fail(function () { setTimeout(function () { pollStats(url) }, 3000) });
}
