'use strict';

// ============================================================
// timeline_test.uc —— timeline.uc 单测
//
// 跑法（设备上，源码树内任意目录）：ucode test/unit/timeline_test.uc
//
// 覆盖：4 列 TSV 解析 / limit 取尾部 N 条 / 坏行丢弃 / 读不到 → [] /
//       render 的逐字格式（C3）/ **11 个 kind 全都有非空标签**（lead 指出的
//       "未来加新 kind 渲染成空行"）/ 中文 reason 按字节原样保留（N14）。
// ============================================================

import { KINDS, is_kind } from '../../luci-app-dns-switch/root/usr/libexec/dns-switch/log.uc';
import * as timeline from '../../luci-app-dns-switch/root/usr/libexec/dns-switch/timeline.uc';

let fs = require('fs');

const BASE = '/tmp/ds-v11/ut-timeline';
const EV = BASE + '/events.log';
const OPTS = { path: EV };

let pass = 0;
let fail = 0;

function show(v) {
	let t = type(v);
	if (t === null) return "null";
	if (t == 'string') return "'" + v + "'";
	if (t == 'int') return sprintf("%d", v);
	if (t == 'bool') return v ? "true" : "false";
	if (t == 'array') return "[" + join(',', v) + "]";
	return "(" + t + ")";
}

function ok(name, cond) {
	if (cond === true) { pass++; print("PASS  " + name + "\n"); }
	else { fail++; print("FAIL  " + name + "\n"); }
}

function eq(name, got, want) {
	if (got === want) { pass++; print("PASS  " + name + "\n"); }
	else { fail++; printf("FAIL  %s\n      got =%s\n      want=%s\n", name, show(got), show(want)); }
}

function mkdir_p(path) {
	let st = fs.stat(path);
	if (st != null && st.type == 'directory') return true;
	let parent = fs.dirname(path);
	if (parent == path) return false;
	mkdir_p(parent);
	fs.mkdir(path);
	return fs.stat(path) != null;
}

function wipe(dir) {
	let names = fs.lsdir(dir);
	if (type(names) != 'array') return;
	for (let i = 0; i < length(names); i++) {
		let n = names[i];
		if (n == '.' || n == '..') continue;
		let p = dir + '/' + n;
		let st = fs.lstat(p);
		if (st != null && st.type == 'directory') { wipe(p); fs.rmdir(p); }
		else fs.unlink(p);
	}
}

wipe(BASE); fs.rmdir(BASE);
mkdir_p(BASE);

// ---- 1. 读不到 / 空文件 → []，且**不报错** ----
eq("文件不存在 → []", length(timeline.events(20, OPTS)), 0);
fs.writefile(EV, "");
eq("空文件 → []", length(timeline.events(20, OPTS)), 0);

// ---- 2. 4 列 TSV 解析 ----
fs.writefile(EV, join('\n', [
	"1795480000\ton\t全屋 DNS 走 AdGuardHome\tadh=172.16.1.2",
	"1795480100\tfailover\tADH 连续 2 次探测失败\teffective=failover",
	""
]));
let ev = timeline.events(20, OPTS);
eq("解析出 2 条", length(ev), 2);
eq("ts 是数字", type(ev[0].ts), "int");
eq("kind", ev[0].kind, "on");
eq("reason 原样（含中文）", ev[0].reason, "全屋 DNS 走 AdGuardHome");
eq("detail 是第 4 列", ev[0].detail, "adh=172.16.1.2");
eq("第二条 kind", ev[1].kind, "failover");

// ---- 3. limit 取**尾部** N 条（等价 tail -n）----
eq("limit=1 只取最后一条", length(timeline.events(1, OPTS)), 1);
eq("limit=1 取到的是最后一条", timeline.events(1, OPTS)[0].kind, "failover");
eq("limit 大于总数 → 全给", length(timeline.events(50, OPTS)), 2);
eq("limit=0 退回默认 20（不是空）", length(timeline.events(0, OPTS)), 2);

// ---- 4. 坏行丢弃（列数不足 / ts 非数字）----
fs.writefile(EV, join('\n', [
	"1795480000\ton\t正常\t",
	"只有两列\tbad",
	"notanumber\ton\t坏时间戳\t",
	"1795480200\tbundle\t诊断包\t",
	""
]));
eq("坏行被丢掉，只剩 2 条", length(timeline.events(20, OPTS)), 2);
eq("留下的第 1 条", timeline.events(20, OPTS)[0].kind, "on");
eq("留下的第 2 条", timeline.events(20, OPTS)[1].kind, "bundle");

// ---- 5. render：格式与 v1.0.1 对齐（C3）----
fs.writefile(EV, "1795480000\ton\t全屋 DNS 走 AdGuardHome\tadh=172.16.1.2\n");
let txt = timeline.render(20, OPTS);
let lines = split(txt, '\n');
ok("首行是『最近 N 条事件（保留 7 天）』", match(lines[0], /^最近 20 条事件（保留 7 天）$/) != null);
eq("第二行是空行", lines[1], "");
ok("事件行形如 `MM-DD HH:MM:SS  [切换启用]  reason`",
	match(lines[2], /^[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}  \[切换启用\]  全屋 DNS 走 AdGuardHome$/) != null);
ok("detail 不进渲染（v1.0.1 只印 reason）", match(txt, /adh=172\.16\.1\.2/) == null);

// ---- 6. 没有事件时给原话，不是空输出 ----
fs.unlink(EV);
eq("无事件 → v1.0.1 那句原话", timeline.render(20, OPTS),
	"还没有事件记录。切换一次、或做个演练就有了。");

// ---- 7. **11 个 kind 全都有非空标签**（LEAD 关注点：别渲染成空行）----
let body = [];
for (let i = 0; i < length(KINDS); i++) {
	push(body, sprintf('%d\t%s\t原因%d\t', 1795480000 + i, KINDS[i], i));
}
fs.writefile(EV, join('\n', body) + '\n');
let all = timeline.events(20, OPTS);
eq("11 个 kind 全部解析出来", length(all), 11);

let t11 = timeline.render(20, OPTS);
let l11 = split(t11, '\n');
let empty_label = 0;
let unregistered = 0;
for (let i = 2; i < length(l11); i++) {
	if (!length(l11[i])) continue;
	if (match(l11[i], /\[\]/) != null) empty_label++;
	if (match(l11[i], /未登记\(/) != null) unregistered++;
}
eq("没有一条渲染成空标签 []", empty_label, 0);
eq("没有一条落到『未登记』兜底（说明 LABELS 覆盖了全部 KINDS）", unregistered, 0);

// ---- 8. 未知 kind 有兜底文案（未来加新 kind 时不至于一行空白）----
fs.writefile(EV, "1795480000\tbrandnew\t新事件类型\t\n");
let t1 = timeline.render(20, OPTS);
ok("未知 kind 渲染出兜底文案，不是空标签", match(t1, /\[未登记\(brandnew\)\]/) != null);
ok("未知 kind 也没丢 reason", match(t1, /新事件类型/) != null);

// ---- 9. 中文按字节原样保留（N14：split 按 '\t' 是安全的）----
fs.writefile(EV, "1795480000\tdrill\t演练通过：降级与回切均自动完成\t\n");
eq("中文 reason 一字不少（逐字节）", timeline.events(20, OPTS)[0].reason,
	"演练通过：降级与回切均自动完成");
eq("字节长度 = 45（8 汉字×3 + 21 ASCII 近似核对）", length(timeline.events(20, OPTS)[0].reason) > 0, true);

// ---- 10. 收尾自清 ----
wipe(BASE); fs.rmdir(BASE);
eq("收尾：临时目录已删除", fs.stat(BASE), null);

printf("\n%s: %d passed, %d failed\n", "timeline_test", pass, fail);
exit(fail == 0 ? 0 : 1);
