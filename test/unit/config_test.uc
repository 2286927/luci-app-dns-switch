'use strict';

// ============================================================
// config_test.uc —— config.uc 单测（uci 根指到 /tmp，绝不碰 /etc）
//
// 跑法（设备上，从源码树根）：ucode test/unit/config_test.uc
// 断言失败 → 退出码 1。
//
// 覆盖：出厂配置补建 / §3.4 缺省 resolve（缺键 + 空值两种）/ status 段补建 /
//       sig() 与 v1.0.1 sig_now 逐字节一致 / state_set 值不变不写 /
//       commit 未提交 = 空操作 / commit 失败 → E_UCI_COMMIT
// ============================================================

import * as config from '../../luci-app-dns-switch/root/usr/libexec/dns-switch/config.uc';
import * as state from '../../luci-app-dns-switch/root/usr/libexec/dns-switch/state.uc';

let fs = require('fs');

const BASE = '/tmp/ds-v11/ut-cfg';
const CONF = BASE + '/dns_switch';

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

// fs.mkdir 不建父目录（lock.uc 里也踩过这条），而 /tmp/ds-v11 在全新机器上
// 根本不存在 —— 必须自己把父目录补齐，否则"干净起点跑单测"直接 E_UCI_COMMIT。
function mkdir_p(path) {
	let st = fs.stat(path);
	if (st != null && st.type == 'directory') return true;
	let parent = fs.dirname(path);
	if (parent != path) mkdir_p(parent);
	fs.mkdir(path);
	st = fs.stat(path);
	return (st != null && st.type == 'directory');
}

// 收尾用：目录不存在时跳过。实测 fs.rmdir / fs.unlink 对不存在的路径都是**返回
// null、不抛异常**，所以这里显式判 stat 不是为了防崩，而是为了"到底删没删掉"
// 这件事能被断言（返回值 null 无法区分"删掉了"和"本来就没有"）。
function rm_if_exists(path) {
	let st = fs.stat(path);
	if (st == null) return true;
	if (st.type == 'directory') { wipe_dir(path); return fs.rmdir(path) != null; }
	return fs.unlink(path) != null;
}

rm_if_exists(BASE);
mkdir_p(BASE);

// ---- 0. 没 open/load 就 commit：不许静默成功 ----
// 写路径在 state（config 不提供别名），所以这里直接打 state.commit()。
let r = state.commit();
eq("未 load 就 commit → ok=false", r.ok, false);
eq("未 load 就 commit → E_INTERNAL", r.code, "E_INTERNAL");
eq("未 load 时 sig() 为空串", config.sig(), "");

// ---- 1. 配置文件不存在 → 按 v1.0.1 ensure_config 建出来 ----
eq("起步时没有配置文件", fs.stat(CONF), null);
let c = config.load({ confdir: BASE });
eq("load() ok", c.ok, true);
eq("load() code=OK", c.code, "OK");
ok("配置文件已建", fs.stat(CONF) != null);

let text = fs.readfile(CONF);
ok("建出来的文件含 config settings 'settings'", match(text, /config settings 'settings'/) != null);
ok("建出来的文件含 config status 'status'", match(text, /config status 'status'/) != null);
ok("建出来的文件含 option isp_list4", match(text, /option isp_list4 '202\.103\.224\.68 202\.103\.225\.68'/) != null);

// ---- 2. §3.4 缺省值在 load() 里已 resolve ----
eq("mode 默认 off", c.settings.mode, "off");
eq("adh_ip 默认 172.16.1.2", c.settings.adh_ip, "172.16.1.2");
eq("adh_port 保持 uci 的字符串", c.settings.adh_port, "3030");
eq("adh_port 类型是 string", type(c.settings.adh_port), "string");
eq("fallback_dns 默认 172.16.5.5", c.settings.fallback_dns, "172.16.5.5");
eq("fallback_dns6 默认空", c.settings.fallback_dns6, "");
eq("adh_mac 默认空", c.settings.adh_mac, "");
eq("dot853 默认 allow", c.settings.dot853, "allow");
eq("upstream_mode 默认 auto", c.settings.upstream_mode, "auto");
eq("probe_domain 默认 www.baidu.com", c.settings.probe_domain, "www.baidu.com");
eq("isp_list 遗留字段默认空", c.settings.isp_list, "");

// ---- 3. opt() ----
eq("opt(mode) 取到已 resolve 值", config.opt('mode', 'X'), "off");
eq("opt(表外键) 用传入的 def", config.opt('no_such_key', 'D'), "D");

// ---- 4. sig() 必须与 v1.0.1 sig_now 逐字节一致 ----
//     v1.0.1: "$ADH|$ADH_PORT|$FB|$FB6|$DOT853|$MAC_CFG|$UPSTREAM_MODE|isp_list4|isp_list6"
eq("sig() 逐字节一致",
	config.sig(),
	"172.16.1.2|3030|172.16.5.5||allow||auto|202.103.224.68 202.103.225.68|");

// ---- 5. status 段字段（缺键归一化成空串，不发明默认值）----
eq("status.effective = off（出厂值）", c.status.effective, "off");
eq("status.probe = unknown", c.status.probe, "unknown");
eq("status.conflict = none", c.status.conflict, "none");
eq("status.error 缺省为空串不是 null", type(c.status.error), "string");
eq("status.applied_sig 缺省为空串", c.status.applied_sig, "");

// ---- 6. state_set + commit 生效 ----
eq("state_set(effective,on) 返回 true", state.set_status('effective', 'on'), true);
eq("同一值再写一次仍 true（不重复写 flash）", state.set_status('effective', 'on'), true);
eq("state_set 数字按字符串写", state.set_status('last_change', 1763952000), true);
r = state.commit();
eq("commit() ok", r.ok, true);
eq("commit() code=OK", r.code, "OK");

let again = config.load({ confdir: BASE });
eq("重读后 effective=on", again.status.effective, "on");
eq("重读后 last_change 是字符串", again.status.last_change, "1763952000");

// 没有改动时 commit() 是空操作
r = state.commit();
eq("无改动 commit() ok", r.ok, true);

// ---- 7. 缺键 / 空值都 resolve 成默认（对应 shell 的 ${X:-default}）----
fs.writefile(CONF, join('\n', [
	"config settings 'settings'",
	"\toption mode 'on'",
	"\toption adh_port ''",
	"",
	"config status 'status'",
	"\toption effective 'off'",
	""
]));
c = config.load({ confdir: BASE });
eq("缺 adh_ip → 默认 172.16.1.2", c.settings.adh_ip, "172.16.1.2");
eq("adh_port 空值 → 默认 3030", c.settings.adh_port, "3030");
eq("mode 有值就用值（on）", c.settings.mode, "on");
eq("缺 dot853 → 默认 allow", c.settings.dot853, "allow");
eq("sig() 跟着变（adh_port 回到 3030）",
	config.sig(), "172.16.1.2|3030|172.16.5.5||allow||auto||");

// ---- 8. status 段缺失 → 补建 + 记日志 + 之后能写 ----
fs.writefile(CONF, join('\n', [
	"config settings 'settings'",
	"\toption mode 'off'",
	""
]));
c = config.load({ confdir: BASE });
eq("缺 status 段时 load() 仍 ok", c.ok, true);
text = fs.readfile(CONF);
ok("status 段被补建", match(text, /config status 'status'/) != null);
eq("补建后 status.effective 是空串", c.status.effective, "");
eq("补建后能正常 state_set", state.set_status('probe', 'ok'), true);
eq("补建后 commit ok", state.commit().ok, true);
eq("重读看到 probe=ok", config.load({ confdir: BASE }).status.probe, "ok");

// ---- 9. 重复 load 不重复写、不再补建 ----
let t1 = fs.readfile(CONF);
config.load({ confdir: BASE });
config.load({ confdir: BASE });
eq("多次 load 文件字节不变", fs.readfile(CONF), t1);

// ---- 10. commit 失败 → E_UCI_COMMIT（confdir 不可写）----
let bad = config.load({ confdir: '/tmp/ds-v11/ut-cfg-nodir/deeper' });
eq("目录不存在时 load() ok=false", bad.ok, false);
eq("目录不存在时 code=E_UCI_COMMIT", bad.code, "E_UCI_COMMIT");
ok("失败时带人话 message", type(bad.message) == "string" && length(bad.message) > 0);

// ---- 10b. 方案 B：失败也返回完整骨架（空哨兵，不用 null）----
// 没有这一段，漏判 ok 的消费方会 `cfg.status.effective` 对 null 取字段 → rc=254 崩溃，
// 而 254 不在 §4.2 的 0/1/2/3/4/75 里，脚本侧完全看不懂。
ok("失败时 settings 仍然存在（方案 B 的核心）", bad.settings != null);
ok("失败时 status 仍然存在", bad.status != null);
eq("骨架 settings.mode 是空串", bad.settings.mode, "");
eq("骨架 settings.adh_port 是空串", bad.settings.adh_port, "");
eq("骨架 status.effective 是空串", bad.status.effective, "");
eq("骨架空哨兵是 string 不是 null（N2：type(null) 判不出来）", type(bad.status.effective), "string");
eq("骨架 status.last_change 是数值 0（唯一数值字段）", bad.status.last_change, 0);
eq("骨架 status.error 是空串", bad.status.error, "");
eq("失败时 sig() 返回空串（不拿骨架拼签名）", config.sig(), "");
eq("失败时 opt() 拿到空哨兵空串（既不是 def 也不是 null）", config.opt("mode", "DEF"), "");

// ---- 10c. 元测试：守方案 B 唯一的失守方式（错误变安静）----
// 骨架让"漏判 ok"不再崩，代价是它会静默读到空值。所以同时钉住两件事：
//   ① 漏判的消费方不崩，只拿到空哨兵；
//   ② 查了 ok 的消费方能拿到可读错误码 —— 两者差别只在有没有查 ok。
function consumer_forgets_ok(c) {
	return "effective=" + c.status.effective + ";mode=" + c.settings.mode;
}

function consumer_checks_ok(c) {
	if (c.ok != true) return "code=" + c.code;
	return "effective=" + c.status.effective;
}

eq("漏判 ok 的消费方不崩，只读到空哨兵", consumer_forgets_ok(bad), "effective=;mode=");
eq("查了 ok 的消费方拿到可读错误码", consumer_checks_ok(bad), "code=E_UCI_COMMIT");
ok("同一个骨架、两个消费方结论不同 —— 差别只在有没有查 ok",
	consumer_checks_ok(bad) != consumer_forgets_ok(bad));

// ---- 11. 收尾：把自己的临时目录清干净，下一轮/CI 才是干净起点 ----
eq("收尾：ut-cfg 已删除", rm_if_exists(BASE), true);
eq("收尾：ut-cfg-nodir 已删除", rm_if_exists('/tmp/ds-v11/ut-cfg-nodir'), true);
eq("收尾：ut-cfg 目录确实不存在", fs.stat(BASE), null);

printf("\n%s: %d passed, %d failed\n", "config_test", pass, fail);
exit(fail == 0 ? 0 : 1);
