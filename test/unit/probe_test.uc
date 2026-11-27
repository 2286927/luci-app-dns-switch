'use strict';

// ============================================================
// probe_test.uc —— probe.uc 单测
//
// 跑法（设备上，源码树内任意目录）：ucode test/unit/probe_test.uc
// 断言失败 → 退出码 1。
//
// 覆盖：via 三态（curl / dns / none）、via='none' 必须带 reason、
//       reason() 文案与 v1.0.1 逐字对齐、isps 的 manual/auto/兜底三路、
//       adh_v6 与 fb_reach 的"探测不到不报错"。
//
// 安全：所有探测都指到**确定不通**的地址（127.0.0.1 的随机高位端口）或
// 127.0.0.1 本机解析，绝不拿真 ADH 地址做断言——否则测试结果取决于现场。
// ============================================================

import * as probe from '../../luci-app-dns-switch/root/usr/libexec/dns-switch/probe.uc';

let fs = require('fs');

const BASE = '/tmp/ds-v11/ut-probe';
const DEAD_IP = '127.0.0.1';
const DEAD_PORT = 9;          // discard 端口，本机几乎不会有服务

let pass = 0;
let fail = 0;

function show(v) {
	let t = type(v);
	if (t === null) return "null";
	if (t == 'string') return "'" + v + "'";
	if (t == 'int') return sprintf("%d", v);
	if (t == 'double') return sprintf("%d", v);
	if (t == 'bool') return v ? "true" : "false";
	return "(" + t + ")";
}

function ok(name, cond) {
	if (cond === true) { pass++; print("PASS  " + name + "\n"); }
	else { fail++; print("FAIL  " + name + "\n"); }
}

function eq(name, got, want) {
	if (got === want) { pass++; print("PASS  " + name + "\n"); }
	else {
		fail++;
		printf("FAIL  %s\n      got =%s\n      want=%s\n", name, show(got), show(want));
	}
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
		let st = fs.stat(p);
		if (st != null && st.type == 'directory') { wipe(p); fs.rmdir(p); }
		else fs.unlink(p);
	}
}

function join_words(a) { return join(',', a); }

wipe(BASE); fs.rmdir(BASE);
mkdir_p(BASE);

// ---- 1. have_curl：返回 bool，不抛 ----
eq("have_curl 返回 bool", type(probe.have_curl()), "bool");

// ---- 2. probe() 的 via 三态 ----
// 2a. 有 curl 且 Web 不通 → via='curl' + reason='web-fail'
let r = probe.probe({ ip: DEAD_IP, port: DEAD_PORT, domain: 'invalid.invalid', timeout: 1 });
eq("Web 不通 → ok=false", r.ok, false);
ok("Web 不通 → via 是 curl（有 curl 时不会退回 dns）",
	(r.via == 'curl') || (r.via == 'dns' && probe.have_curl() != true));
eq("Web 不通 → reason 非空（不许静默）", type(r.reason) == "string" && length(r.reason) > 0, true);
ok("ms 是数字且 >= 0", (type(r.ms) == "int" || type(r.ms) == "double") && r.ms >= 0);

// 2b. drill 钩子：文件在有效期内 → via='none' 且**必须带 reason**
let flag = '/tmp/dns-switch.probe-fail';
fs.writefile(flag, sprintf('%d\n', time()));
let rd = probe.probe({ ip: DEAD_IP, port: DEAD_PORT, domain: 'invalid.invalid', timeout: 1 });
eq("演练标记生效 → via='none'", rd.via, "none");
eq("演练标记生效 → ok=false", rd.ok, false);
eq("via='none' **必须**带 reason（硬约束）", rd.reason, "drill");
ok("via='none' 的 reason 不是空串", length(rd.reason) > 0);
fs.unlink(flag);
let rd2 = probe.probe({ ip: DEAD_IP, port: DEAD_PORT, domain: 'invalid.invalid', timeout: 1 });
ok("标记删掉后不再走 none", rd2.via != "none");

// 2c. 过期标记会被自动清除
fs.writefile(flag, sprintf('%d\n', time() - 1000));
let rd3 = probe.probe({ ip: DEAD_IP, port: DEAD_PORT, domain: 'invalid.invalid', timeout: 1 });
ok("过期标记不生效", rd3.via != "none");
eq("过期标记被自动清除", fs.stat(flag), null);

// ---- 3. probe_web / probe_dns 的形状 ----
let w = probe.probe_web(DEAD_IP, DEAD_PORT, 1);
eq("probe_web 回 ok/rc/status/ms/reason 五键", type(w.ok), "bool");
eq("probe_web 失败 status=0", w.status, 0);
ok("probe_web 的 reasoning 非空", length(w.reason) > 0);

let d = probe.probe_dns(DEAD_IP, 'invalid.invalid', 1);
eq("probe_dns 回 ok/ms/reason", type(d.ok), "bool");
ok("probe_dns 解析不存在的域名 → ok=false", d.ok == false);

// ---- 4. reason()：C11 文案（与 v1.0.1 逐字对齐）----
eq("reason('ok')", probe.reason('ok'), "正常");
eq("reason('web-fail') 带端口",
	probe.reason('web-fail', { port: 3030 }),
	"Web 3030 不通（AdGuardHome 未运行或地址不对）");
eq("reason('dns-fail')", probe.reason('dns-fail'),
	"Web 有响应但解析失败（ADH 上游不可用）");
eq("reason('nocurl-dns-ok') 带域名",
	probe.reason('nocurl-dns-ok', { domain: 'www.baidu.com' }),
	"未安装 curl，仅按 DNS 探测（www.baidu.com 解析正常）");
eq("reason('nocurl-dns-fail') 带域名",
	probe.reason('nocurl-dns-fail', { domain: 'www.baidu.com' }),
	"未安装 curl，仅按 DNS 探测（www.baidu.com 解析失败）");
ok("未知 code 也给话，不返回空串",
	length(probe.reason('whatever')) > 0);
ok("未知 code 的文案里带原 code（便于定位）",
	match(probe.reason('whatever'), /whatever/) != null);

// ---- 5. isps()：manual / auto / 兜底 三路 ----
let cfg_manual = {
	ok: true,
	settings: {
		upstream_mode: 'manual', isp_list4: '1.1.1.1 8.8.8.8', isp_list6: '2400::1',
		isp_list: '', adh_ip: '172.16.1.2', fallback_dns: '172.16.5.5'
	}
};
let im = probe.isps(cfg_manual);
eq("manual 模式 source", im.source, "manual");
eq("manual v4 按空格拆开", join_words(im.v4), "1.1.1.1,8.8.8.8");
eq("manual v6", join_words(im.v6), "2400::1");

let cfg_legacy = {
	ok: true,
	settings: {
		upstream_mode: 'manual', isp_list4: '', isp_list6: '',
		isp_list: '9.9.9.9 1.0.0.1', adh_ip: '172.16.1.2', fallback_dns: '172.16.5.5'
	}
};
let il = probe.isps(cfg_legacy);
eq("manual 且两列为空 → 用遗留 isp_list", join_words(il.v4), "9.9.9.9,1.0.0.1");
eq("遗留兜底也算 manual", il.source, "manual");

let cfg_auto = {
	ok: true,
	settings: {
		upstream_mode: 'auto', isp_list4: '', isp_list6: '', isp_list: '',
		adh_ip: '172.16.1.2', fallback_dns: '172.16.5.5'
	}
};
let ia = probe.isps(cfg_auto);
eq("auto 模式 source", ia.source, "auto");
ok("auto 至少给出一组（读不到 resolv.conf.auto 时走内置兜底）",
	length(ia.v4) > 0 || length(ia.v6) > 0);
let leaked = 0;
for (let i = 0; i < length(ia.v4); i++) {
	if (match(ia.v4[i], /^127\./) || ia.v4[i] == '172.16.1.2' || ia.v4[i] == '172.16.5.5') leaked++;
}
eq("auto 结果里不含 127./ADH/备用地址", leaked, 0);

eq("cfg 不可读时 isps 不报错、给空表", length(probe.isps({ ok: false }).v4), 0);
eq("cfg 为 null 时 isps 不崩", type(probe.isps(null).source), "string");

// ---- 6. adh_v6 / fb_reach：探测不到不报错 ----
eq("adh_v6(cfg 不可读) → 空串", probe.adh_v6({ ok: false }), "");
eq("adh_v6(null) → 空串", probe.adh_v6(null), "");
eq("fb_reach 未配置 → false",
	probe.fb_reach({ ok: true, settings: { fallback_dns: '' } }), false);
eq("fb_reach 回 bool", type(probe.fb_reach(cfg_auto)), "bool");

// ---- 7. 收尾自清 ----
wipe(BASE); fs.rmdir(BASE);
eq("收尾：临时目录已删除", fs.stat(BASE), null);

printf("\n%s: %d passed, %d failed\n", "probe_test", pass, fail);
exit(fail == 0 ? 0 : 1);
