// @id crawl-fail
// @name 失败源
function fetchNotices() {
  throw new Error("boom");
}
