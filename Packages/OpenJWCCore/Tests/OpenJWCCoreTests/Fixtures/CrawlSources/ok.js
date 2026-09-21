// @id crawl-ok
// @name 正常源
function fetchNotices() {
  return JSON.stringify([
    { id: "n1", label: "通知", title: "第一条", date: "2026-09-21 10:00:00", detail_url: "https://example.com/1", is_page: true },
    { id: "n2", label: "通知", title: "第二条", date: "2026-09-20", detail_url: "https://example.com/2", is_page: false }
  ]);
}
