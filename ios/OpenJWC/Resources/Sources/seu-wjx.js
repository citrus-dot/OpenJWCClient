// @id seu-wjx
// @name 东南大学吴健雄学院
// @version 1.0.0
// @schedule 360
// @domains wjx.seu.edu.cn
// @labels 综合新闻,通知公告,教学信息,学工信息,学生活动

// 东南大学吴健雄学院官网（webplus CMS，服务端渲染）。
// 列表页 list.htm → listN.htm；正文统一取 div.wp_articlecontent 并转 Markdown。
// 行/标题/日期选择器对站内几种 webplus 模板做了兼容（news_list / wp_article_list / jzlb）。
var HOST = "https://wjx.seu.edu.cn";
var DOMAIN = "wjx.seu.edu.cn";
var ROW_SELECTOR = ".col_news_list .news_list li.news";
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
  ["综合新闻", "/zhxw/list.htm"],
  ["通知公告", "/tzgg/list.htm"],
  ["教学信息", "/xjxxx/list.htm"],
  ["学工信息", "/xxgxx/list.htm"],
  ["学生活动", "/xshd/list.htm"],
];

// 行内标题链接的选择器（按顺序尝试，取第一个有非空标题的 <a>）
var TITLE_SELECTORS = [".news_title a", ".Article_Title a", "a"];
// 行内日期的选择器（按顺序尝试，取第一个能解析出日期的）
var DATE_SELECTORS = [".news_meta", ".Article_PublishDate", ".news_time", ".news_timer", ".fbsj4", "td[width='30px'] div"];
// 日期格式：2026-09-04 / 2026.09.04 / 202609.04 / 09.042026
var DATE_RE_YMD = /(\d{4})[.\-\/]?(\d{2})[.\-\/](\d{2})/;
var DATE_RE_DMY = /(\d{2})[.\-\/](\d{2})[.\-\/]?(\d{4})/;

function isAttachment(url) {
  return ATTACH_RE.test(url.split("?")[0]);
}

function textOf(html, selector) {
  return dom.text(html, selector).trim();
}

/** 解析日期为 yyyy-MM-dd；无法解析返回 null。 */
function parseDate(raw) {
  if (!raw) return null;
  var s = raw.replace(/\s+/g, "");
  var m = s.match(DATE_RE_YMD);
  if (m) return m[1] + "-" + m[2] + "-" + m[3];
  m = s.match(DATE_RE_DMY);
  if (m) return m[3] + "-" + m[1] + "-" + m[2];
  return null;
}

/** 行内标题链接：优先 title 属性，其次 .news_title 文本，最后 <a> 文本。 */
function titleLink(rowHtml) {
  for (var s = 0; s < TITLE_SELECTORS.length; s++) {
    var links = JSON.parse(dom.query(rowHtml, TITLE_SELECTORS[s]));
    for (var i = 0; i < links.length; i++) {
      var a = links[i];
      if (!a.attrs.href) continue;
      var title = a.attrs.title;
      if (!title) {
        var inner = JSON.parse(dom.query(a.html, ".news_title"));
        title = inner.length ? inner[0].text : a.text;
      }
      title = (title || "").replace(/\s+/g, " ").trim();
      if (title) return { title: title, href: a.attrs.href };
    }
  }
  return null;
}

/** 行内日期：先试常见日期元素，再回退到整行文本。 */
function dateOf(rowHtml, rowText) {
  for (var i = 0; i < DATE_SELECTORS.length; i++) {
    var d = parseDate(textOf(rowHtml, DATE_SELECTORS[i]));
    if (d) return d;
  }
  return parseDate(rowText);
}

/** 末页：读取 em.all_pages（解析失败按 1 处理）。 */
function allPagesOf(html) {
  var value = parseInt(textOf(html, ALL_PAGES_SELECTOR), 10);
  return value > 0 ? value : 1;
}

/** 收集正文里的附件（href 与 pdfsrc 都看），去重。 */
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
      var listHtml;
      try {
        listHtml = http.get(listUrl);
      } catch (e) {
        stats.failed++;
        report.warn("栏目「" + label + "」列表页不可访问：" + listUrl + "（" + e + "）");
        console.log("list failed " + listUrl + ": " + e);
        break;
      }

      var rows = JSON.parse(dom.query(listHtml, ROW_SELECTOR));
      if (!rows.length) break;

      var freshInPage = 0;
      for (var r = 0; r < rows.length; r++) {
        var row = rows[r];
        var link = titleLink(row.html);
        if (!link) continue;

        stats.scanned++;
        var date = dateOf(row.html, row.text);
        if (!date) {
          // 没有日期就没法归入时间范围，只能丢弃
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

        var detailUrl = util.resolveUrl(listUrl, link.href);
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
        // 站外链接（如微信公众号）只存标题与链接，不抓正文
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
          title: link.title,
          date: date,
          detail_url: detailUrl,
          is_page: isPage,
          content_text: contentText,
          attachments: attachments
        });
      }

      // 每翻一页上报一次进度，App 端在抓取对话框里展示详细日志
      // 每翻一页上报一次进度（含整体完成比例），App 端据此画更细粒度的进度条
      var totalPages = allPagesOf(listHtml);
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
