// @id seu-cs
// @name 东南大学计算机学院
// @version 2.3.0
// @schedule 360
// @domains cs.seu.edu.cn
// @labels 学院新闻,通知公告,学术活动

// 选择器与分页对齐 JwcCrawler（src/crawl/seu-cs.rs）
var HOST = "https://cs.seu.edu.cn";
var DOMAIN = "cs.seu.edu.cn";
var ROW_SELECTOR = "ul.news_list li.news";
var TITLE_LINK_SELECTOR = "span.news_title a";
var DATE_SELECTOR = "span.news_meta";
var BODY_SELECTOR = "div.wp_articlecontent";
var ALL_PAGES_SELECTOR = "em.all_pages";
var ATTACH_RE = /\.(pdf|doc|docx|xls|xlsx|zip|rar)$/i;
// 校内 IP 限制页面的特征文案
var CAMPUS_ONLY_HINT = "仅允许校内地址访问";

// 单次运行最多抓多少条正文；剩下的留给下次运行继续（已入库的条目会跳过，不会重复抓）
var MAX_DETAILS_PER_RUN = 120;
// 单次运行每个栏目最多翻多少页（真实末页由 em.all_pages 决定）
var MAX_PAGES = 30;
// 警告样本上限（总数仍计入统计）
var MAX_DETAIL_WARNINGS = 5;
var MAX_DATE_WARNINGS = 3;

var CATEGORIES = [
  ["学院新闻", "/news/list.htm"],
  ["通知公告", "/49342/list.htm"],
  ["学术活动", "/xshd_53564/list.htm"]
];

function isAttachment(url) {
  return ATTACH_RE.test(url.split("?")[0]);
}

function textOf(html, selector) {
  return dom.text(html, selector).trim();
}

/** 末页：读取 em.all_pages（对齐 JwcCrawler，解析失败按 1 处理）。 */
function allPagesOf(html) {
  var value = parseInt(textOf(html, ALL_PAGES_SELECTOR), 10);
  return value > 0 ? value : 1;
}

/** 行内标题链接（对齐 JwcCrawler 的 list_title_link，并要求有 title 属性）。 */
function titleLink(rowHtml) {
  var links = JSON.parse(dom.query(rowHtml, TITLE_LINK_SELECTOR));
  for (var i = 0; i < links.length; i++) {
    if (links[i].attrs.title) return links[i];
  }
  return null;
}

/** 行内日期：优先取 list_date 元素，其次回退到整行文本。 */
function dateOf(row) {
  var scoped = textOf(row.html, DATE_SELECTOR);
  var match = scoped.match(/\d{4}-\d{2}-\d{2}/);
  if (match) return match[0];
  match = row.text.match(/\d{4}-\d{2}-\d{2}/);
  return match ? match[0] : null;
}

/** 收集正文里的附件（href 与 pdfsrc 都看，对齐 JwcCrawler），去重。 */
function collectAttachments(page, baseUrl) {
  var seen = {};
  var out = [];
  function add(raw) {
    if (!raw) return;
    var full = util.resolveUrl(baseUrl, raw);
    if (!isAttachment(full) || seen[full]) return;
    seen[full] = true;
    out.push(full);
  }
  var links = JSON.parse(dom.query(page, BODY_SELECTOR + " a"));
  for (var i = 0; i < links.length; i++) add(links[i].attrs.href);
  var embeds = JSON.parse(dom.query(page, BODY_SELECTOR + " [pdfsrc]"));
  for (var j = 0; j < embeds.length; j++) add(embeds[j].attrs.pdfsrc);
  return out.length ? out : null;
}

/** 抓详情正文（Markdown）。抓不到时 ok=false，由调用方决定是否仍入库。 */
function fetchDetail(url) {
  var page;
  try {
    page = http.get(url);
  } catch (e) {
    return { ok: false, restricted: false, reason: "请求失败 " + e };
  }
  var parts = JSON.parse(dom.query(page, BODY_SELECTOR));
  if (!parts.length) {
    if (page.indexOf(CAMPUS_ONLY_HINT) >= 0) {
      return { ok: false, restricted: true, reason: "仅校内可访问" };
    }
    return { ok: false, restricted: false, reason: "正文选择器 " + BODY_SELECTOR + " 未命中" };
  }
  var markdown = dom.markdown(page, BODY_SELECTOR, url);
  if (!markdown) {
    // 选择器命中但内容为空：多为 PDF / 附件型通知
    return { ok: false, restricted: false, reason: "正文为空（可能是附件/PDF 型通知）" };
  }
  return { ok: true, restricted: false, text: markdown, attachments: collectAttachments(page, url) };
}

/** 列表页地址：list.htm → list2.htm → list3.htm … */
function pageUrl(path, page) {
  if (page <= 1) return HOST + path;
  return HOST + path.replace("list", "list" + page);
}

function finish(notices, stats) {
  if (stats.noContent > 0) {
    report.warn("有 " + stats.noContent + " 条资讯只存了标题与链接，正文暂缺（校内限制、正文为空或选择器失效），下次抓取会自动重试");
  }
  if (stats.restricted > 0) {
    report.warn("其中 " + stats.restricted + " 条仅校内 IP 可访问，在校内网络重抓可补全正文");
  }
  report.stats(
    stats.scanned,
    stats.skipped,
    stats.failed,
    stats.noContent,
    stats.restricted,
    stats.skippedOld,
    stats.skippedDuplicate,
    stats.skippedKnown
  );
  return notices;
}

function fetchNotices() {
  var cutoff = params.crawlCutoffDate();
  var known = JSON.parse(params.knownIdsJson());
  var knownSet = {};
  for (var k = 0; k < known.length; k++) knownSet[known[k]] = true;

  var result = [];
  var seen = {};
  var details = 0;
  var stats = {
    scanned: 0,
    skipped: 0,
    failed: 0,
    noContent: 0,
    restricted: 0,
    skippedOld: 0,
    skippedDuplicate: 0,
    skippedKnown: 0
  };
  var detailWarnings = 0;
  var dateWarnings = 0;

  for (var c = 0; c < CATEGORIES.length; c++) {
    var label = CATEGORIES[c][0];
    var path = CATEGORIES[c][1];
    var matchedInCategory = 0;

    for (var page = 1; page <= MAX_PAGES; page++) {
      var listUrl = pageUrl(path, page);
      var html;
      try {
        html = http.get(listUrl);
      } catch (e) {
        stats.failed++;
        report.warn("栏目「" + label + "」列表页不可访问：" + listUrl + "（" + e + "）");
        console.log("list failed " + listUrl + ": " + e);
        break;
      }

      var rows = JSON.parse(dom.query(html, ROW_SELECTOR));
      if (!rows.length) break;

      var freshInPage = 0;
      for (var r = 0; r < rows.length; r++) {
        var row = rows[r];
        var link = titleLink(row.html);
        if (!link) continue;

        stats.scanned++;
        var date = dateOf(row);
        if (!date) {
          // 没有日期就没法归入时间范围，只能丢弃（与 JwcCrawler 一致）
          stats.failed++;
          if (dateWarnings < MAX_DATE_WARNINGS) {
            dateWarnings++;
            report.warn("栏目「" + label + "」有列表行没有日期：" + (row.text || "").substring(0, 100));
          }
          continue;
        }
        matchedInCategory++;
        if (date < cutoff) {
          stats.skipped++;
          stats.skippedOld++;
          continue;
        }
        freshInPage++;

        var detailUrl = util.resolveUrl(listUrl, link.attrs.href || "");
        if (seen[detailUrl]) {
          stats.skipped++;
          stats.skippedDuplicate++;
          continue;
        }
        seen[detailUrl] = true;

        var id = util.sha256(detailUrl);
        if (knownSet[id]) {
          stats.skipped++;
          stats.skippedKnown++;
          continue;
        }

        var isPage = !isAttachment(detailUrl);
        var contentText = null;
        var attachments = null;
        if (isPage && detailUrl.indexOf(DOMAIN) >= 0) {
          if (details >= MAX_DETAILS_PER_RUN) return finish(result, stats);
          var detail = fetchDetail(detailUrl);
          details++;
          if (detail.ok) {
            contentText = detail.text;
            attachments = detail.attachments;
          } else {
            // 正文抓不到也照样入库（标题 + 链接），下次抓取会重试补正文
            stats.noContent++;
            if (detail.restricted) stats.restricted++;
            if (detailWarnings < MAX_DETAIL_WARNINGS) {
              detailWarnings++;
              report.warn("正文暂缺：" + detailUrl + "（" + detail.reason + "）");
            }
          }
        }

        result.push({
          id: id,
          label: label,
          title: link.attrs.title,
          date: date,
          detail_url: detailUrl,
          is_page: isPage,
          content_text: contentText,
          attachments: attachments
        });
      }

      // 每翻一页上报一次进度，App 端在抓取对话框里展示详细日志
      // 每翻一页上报一次进度（含整体完成比例），App 端据此画更细粒度的进度条
      var totalPages = allPagesOf(html);
      report.progress(
        stats.scanned,
        stats.skipped,
        stats.failed,
        (c + page / totalPages) / CATEGORIES.length,
        "「" + label + "」第 " + page + " 页"
      );
      if (freshInPage === 0 || page >= totalPages) break;
    }

    if (matchedInCategory === 0) {
      stats.failed++;
      report.warn("栏目「" + label + "」未解析到资讯，请检查站点结构");
    }
  }

  return finish(result, stats);
}
