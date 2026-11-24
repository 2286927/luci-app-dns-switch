'use strict';

// ============================================================
// log_test.uc —— log.uc 单测
//
// 跑法（设备上，从源码树根）：ucode test/unit/log_test.uc
// 断言失败 → 退出码 1。
//
// 覆盖：events.log **4 列 TSV** / kind 枚举 / 换行制表符清洗 /
//       路径自动建父目录 / prune 保留期 / 写失败不抛异常
// ============================================================

import * as log from '../../luci-app-dns-switch/root/usr/libexec/dns-switch/log.uc';

let fs = require('fs');

const BASE = '/tmp/ds-v11/ut-log';
const EV = BASE + '/events.log';

let pass = 0;
let fail = 0;

function ok(name, cond) {
	if (cond === true) { pass++; print("PASS  " + name + "\n"); }
	else { fail++; print("FAIL  " + name + "\n"); }
}

// 注意：ucode 的 type(null) 返回 null 本身（不是字符串 "null"），判空一律 === null
function show(v) {
	let t = type(v);
	if (t === null) return "null";
	if (t == 'string') return "'" + v + "'";
	if (t == 'int') return sprintf("%d", v);
	if (t == 'bool') return v ? "true" : "false";
	return "(" + t + ")";
}

function eq(name, got, want) {
	if (got === want) { pass++; print("PASS  " + name + "\n"); }
	else {
		fail++;
		printf("FAIL  %s\n      got =%s\n      want=%s\n", name, show(got), show(want));
	}
}

function wipe_dir(dir) {
	let names = fs.lsdir(dir);
	if (type(names) != 'array') return;
	for (let i = 0; i < length(names); i++) {
		let n = names[i];
		if (n == '.' || n == '..') continue;
		let p = dir + '/' + n;
		let st = fs.stat(p);
		if (st != null && st.type == 'directory') { wipe_dir(p); fs.rmdir(p); }
		else fs.unlink(p);
	}
}

function lines_of(path) {
	let raw = fs.readfile(path);
	if (type(raw) != 'string') return [];
	let out = [];
	let parts = split(raw, '\n');
	for (let i = 0; i < length(parts); i++) {
		if (length(parts[i])) push(out, parts[i]);
	}
	return out;
}

wipe_dir(BASE); fs.rmdir(BASE);

// ---- 1. kind 枚举（C8，11 个，一个不多一个不少）----
eq("KINDS 数量 = 11", length(log.KINDS), 11);
let want_kinds = [ 'on', 'off', 'failover', 'recover', 'drift', 'repair',
                   'conflict', 'drill', 'rescue', 'snapshot', 'bundle' ];
let all_ok = true;
for (let i = 0; i < length(want_kinds); i++)
	if (!log.is_kind(want_kinds[i])) { all_ok = false; print("  missing kind: " + want_kinds[i] + "\n"); }
eq("11 个枚举值全部 is_kind", all_ok, true);
eq("非法 kind 被识别", log.is_kind("bogus"), false);

// ---- 2. ev() 写出 4 列 TSV ----
eq("ev() 返回 true", log.ev('on', '全屋 DNS 走 AdGuardHome', 'adh=172.16.1.2', { path: EV }), true);

let ls = lines_of(EV);
eq("写出 1 行", length(ls), 1);
let f = split(ls[0], '\t');
eq("4 列", length(f), 4);
eq("第 1 列是时间戳（int）", type(+f[0]), "int");
ok("第 1 列接近当前时间", (+f[0] - time()) >= -3 && (+f[0] - time()) <= 3);
eq("第 2 列 kind", f[1], "on");
eq("第 3 列 reason", f[2], "全屋 DNS 走 AdGuardHome");
eq("第 4 列 detail", f[3], "adh=172.16.1.2");

// ---- 3. 换行/制表符清洗（否则一条事件会被拆成多行）----
log.ev('conflict', "多行\n原因", "a\tb\rc", { path: EV });
ls = lines_of(EV);
eq("清洗后仍是 1 行（行数 = 2）", length(ls), 2);
f = split(ls[1], '\t');
eq("清洗后仍是 4 列", length(f), 4);
eq("reason 里的换行变空格", f[2], "多行 原因");
eq("detail 里的 tab/CR 变空格", f[3], "a b c");

// ---- 4. 未知 kind 不丢数据 ----
eq("未知 kind 仍落盘（返回 true）", log.ev('nonsense', 'r', 'd', { path: EV }), true);
ls = lines_of(EV);
eq("未知 kind 写成功（行数 = 3）", length(ls), 3);
eq("未知 kind 原样保留", split(ls[2], '\t')[1], "nonsense");

// ---- 5. 空 kind 直接丢弃 ----
eq("空 kind 返回 false", log.ev('', 'r', 'd', { path: EV }), false);
eq("空 kind 不落盘（行数仍 3）", length(lines_of(EV)), 3);

// ---- 6. 父目录不存在时自动建 ----
fs.unlink(EV);
fs.rmdir(BASE);
eq("events 目录被删掉了", fs.stat(BASE), null);
eq("ev() 自动建父目录", log.ev('off', 'r', 'd', { path: EV }), true);
ok("父目录已建", fs.stat(BASE) != null);
eq("自动建目录后 1 行", length(lines_of(EV)), 1);

// ---- 7. prune 只留 N 天 ----
fs.writefile(EV, join('\n', [
	"0\tfailover\t很久以前（应被删）\t",
	sprintf('%d\ton\t刚刚（应保留）\t', time()),
	"abc\tbundle\t时间戳非法（应被删）\t",
	""
]));
eq("prune 前 3 行", length(lines_of(EV)), 3);
eq("prune() 返回 true", log.prune({ path: EV }), true);
ls = lines_of(EV);
eq("prune 后只剩 1 行", length(ls), 1);
eq("留下的是新行", split(ls[0], '\t')[1], "on");
eq("prune 后仍 4 列", length(split(ls[0], '\t')), 4);

// days 参数：把保留期设为 1 天，刚写的两行都在期内
log.ev('drill', 'x', 'y', { path: EV });
eq("追加后 2 行", length(lines_of(EV)), 2);
eq("prune(days=1) 返回 true", log.prune({ path: EV, days: 1 }), true);
eq("prune(days=1) 保留新行（仍 2 行）", length(lines_of(EV)), 2);

// 没有文件时 prune 不算失败
fs.unlink(EV);
eq("prune 对不存在的文件返回 true", log.prune({ path: EV }), true);

// ---- 8. log/warn/err 不崩（logger 是否存在都要能返回）----
eq("log() 返回 true", log.log('dns-switch 单测：log 出口自检'), true);
eq("warn() 返回 true", log.warn('dns-switch 单测：warn 出口自检'), true);
eq("err() 返回 true", log.err('dns-switch 单测：err 出口自检'), true);

// ---- 9. 写不进去时静默返回 false，不抛异常 ----
eq("路径不可写时 ev() 返回 false",
	log.ev('on', 'r', 'd', { path: '/proc/self/never/events.log' }), false);

wipe_dir(BASE); fs.rmdir(BASE);

printf("\n%s: %d passed, %d failed\n", "log_test", pass, fail);
exit(fail == 0 ? 0 : 1);
