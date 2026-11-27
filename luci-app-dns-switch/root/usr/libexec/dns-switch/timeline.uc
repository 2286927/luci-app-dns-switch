'use strict';

// ============================================================
// timeline.uc —— L2：事件时间线（events.log 的读写与渲染）
//
// 承接 v1.0.1 的 do_timeline。events.log 是 **4 列 TSV**（C8）：ts/kind/reason/detail。
//
// 三条约束：
//   1. 读不到文件 → 返回 `[]`，**不报错**（它只是只读展示，不是执行）
//   2. `length()`/`substr()` 是**字节**语义（N14）：reason 里有中文，按字节算；
//      按 '\t' 切字段是安全的（制表符是单字节 ASCII），但别按"字符数"截断中文
//   3. 未知 kind **必须有兜底文案**：`KINDS` 加新成员时若渲染成空串，页面上
//      就是一行空白——比报错难查得多
//
// 它是 `log.KINDS` / `log.is_kind()` 的第一个生产消费者（这两个导出正是
// A4 查出"代码有、SPEC 无"的那对）。
//
// 依赖：log（KINDS/is_kind）+ sh（date）+ fs
// ============================================================

import { KINDS, is_kind } from './log.uc';
import { runq } from './sh.uc';

let fs = require('fs');

const EVENTS = '/etc/dns-switch/events.log';
const KEEP_DAYS = 7;
const DEFAULT_LIMIT = 20;

// kind → 中文标签（C11 文案；与 v1.0.1 的 cn() 逐字一致）
const LABELS = {
	on: '切换启用', off: '切回原生', failover: '自动降级', recover: '自动回切',
	drift: '发现漂移', repair: '自动修复', conflict: '端口冲突', drill: '链路演练',
	rescue: '急救复位', snapshot: '快照回滚', bundle: '诊断包'
};

// ---------- 工具（必须在使用者之前：N27）----------

function path_of(opts) {
	if (opts != null && type(opts) == 'object') {
		let p = opts.path;
		if (type(p) == 'string' && length(p)) return p;
	}
	return EVENTS;
}

function limit_of(limit) {
	let n = (type(limit) == 'int') ? limit : DEFAULT_LIMIT;
	if (n <= 0) n = DEFAULT_LIMIT;
	return n;
}

/** kind → 中文。未知 kind 回退成 kind 本身，**绝不返回空串**。 */
function label_of(kind) {
	let k = (type(kind) == 'string') ? kind : '';
	if (length(k) && type(LABELS[k]) == 'string') return LABELS[k];
	if (!length(k)) return '未知事件';
	// 不在表里但形状合法：带个标记回来，读数的人一眼知道要补表
	return '未登记(' + k + ')';
}

// 实测：这个 ucode 里 **没有 strftime()**（`access to undeclared variable`），
// 所以时间格式化走 `date`。代价是每条事件一次进程（20 条约 40 ms），
// 只影响 timeline 这条 CLI 命令，不影响 status（status 不读时间线）。
function fmt_ts(ts) {
	let t = (type(ts) == 'int' || type(ts) == 'double') ? ts : 0;
	let r = runq(sprintf('date -d @%d "+%%m-%%d %%H:%%M:%%S"', t));
	let v = trim(r.out);
	if (r.rc == 0 && match(v, /^[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$/) != null) return v;
	return '??-?? ??:??:??';   // 兜底：宁可显示问号，也不要空字符串
}

/** 一行 TSV → 对象。列数不足 3 的行整行丢掉（宁可少一条，不要渲染半行）。 */
function parse_line(line) {
	let f = split(line, '\t');
	if (length(f) < 3) return null;
	let ts = +f[0];
	if (!(ts > 0)) return null;
	return {
		ts: ts,
		kind: f[1],
		reason: (length(f) > 2) ? f[2] : '',
		detail: (length(f) > 3) ? f[3] : ''
	};
}

// ---------- 导出 ----------

/**
 * 最近 limit 条事件（新→旧文件顺序，取尾部 limit 条）。
 * 文件不存在 / 空 / 全是坏行 → `[]`，不报错。
 * opts.path 是单测缝。
 */
export function events(limit, opts) {
	let n = limit_of(limit);
	let raw = fs.readfile(path_of(opts));
	if (type(raw) != 'string' || !length(raw)) return [];

	let lines = split(raw, '\n');
	let all = [];
	for (let i = 0; i < length(lines); i++) {
		let ln = lines[i];
		if (!length(ln)) continue;
		let e = parse_line(ln);
		if (e != null) push(all, e);
	}
	if (length(all) <= n) return all;

	let out = [];
	for (let i = length(all) - n; i < length(all); i++) push(out, all[i]);
	return out;
}

/**
 * 渲染成人话文本。与 v1.0.1 的 do_timeline 逐字对齐（C3）：
 *   首行 `最近 N 条事件（保留 7 天）`、空行、然后每行 `MM-DD HH:MM:SS  [标签]  reason`
 * 没有事件时给 v1.0.1 那句原话，**不是空输出**。
 */
export function render(limit, opts) {
	let n = limit_of(limit);
	let list = events(n, opts);
	if (!length(list)) return '还没有事件记录。切换一次、或做个演练就有了。';

	let out = [ sprintf('最近 %d 条事件（保留 %d 天）', n, KEEP_DAYS), "" ];
	for (let i = 0; i < length(list); i++) {
		let e = list[i];
		push(out, sprintf('%s  [%s]  %s', fmt_ts(e.ts), label_of(e.kind), e.reason));
	}
	return join('\n', out) + '\n';
}
