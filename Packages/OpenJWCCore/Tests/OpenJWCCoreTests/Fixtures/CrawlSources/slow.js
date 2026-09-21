// @id crawl-slow
// @name 慢源
function fetchNotices() {
  var start = Date.now();
  while (Date.now() - start < 3000) {}
  return JSON.stringify([]);
}
