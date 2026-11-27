'use strict';

// ============================================================
// snapshot_test.uc —— snapshot.uc 单测
//
// 跑法（设备上，源码树内任意目录）：ucode test/unit/snapshot_test.uc
//
// **重点 1：读 v1.0.1 旧格式快照（C3）**。fixture 在
//   test/fixtures/snapshot-v101/20261124-083000/{dhcp,hijack.nft,dns_switch.uci,mode}
// 那是 shell 版真机落盘的样子；读不了就意味着用户升级后不能回滚。
//
// **重点 2：restore 的顺序与 onFn 注入**——mode=on 才回调，mode≠on 绝不回调。
// 顺序错了会"用当前那套参数重新下发"，是假回滚。
//
// 安全：全部走测试缝（_snapdir/_dhcp/_frag + skip_reload/skip_verify），
// 绝不碰 /etc、不 reload、不重启 dnsmasq、不 nslookup。
// ============================================================

import * as state from '../../luci-app-dns-switch/root/usr/libexec/dns-switch/state.uc';
import * as snapshot from '../../luci-app-dns-switch/root/usr/libexec/dns-switch/snapshot.uc';

let fs = require('fs');

const BASE = '/tmp/ds-v11/ut-snap';
const SNAPS = BASE + '/snaps';
const CONF = BASE + '/conf';
const DHCP = BASE + '/dhcp';
const FRAG = BASE + '/frag.nft';
const OLDID = '20261124-083000';

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
		let st = fs.lstat(p);
		if (st != null && st.type == 'directory') { wipe(p); fs.rmdir(p); }
		else fs.unlink(p);
	}
}

function find_path(rel) {
	let dir = fs.getcwd();
	for (let i = 0; i < 8; i++) {
		let cand = dir + '/' + rel;
		if (fs.stat(cand) != null) return cand;
		let parent = fs.dirname(dir);
		if (parent == dir) break;
		dir = parent;
	}
	return null;
}

function copy_tree(from, to) {
	mkdir_p(to);
	let names = fs.lsdir(from);
	if (type(names) != 'array') return;
	for (let i = 0; i < length(names); i++) {
		let t = fs.readfile(from + '/' + names[i]);
		if (type(t) == 'string') fs.writefile(to + '/' + names[i], t);
	}
}

const OPTS = {
	_snapdir: SNAPS, _dhcp: DHCP, _frag: FRAG, confdir: CONF,
	skip_reload: true, skip_verify: true
};

wipe(BASE); fs.rmdir(BASE);
mkdir_p(SNAPS);
mkdir_p(CONF);

// ---- 0. 把 v1.0.1 fixture 放进快照目录（这就是"旧快照"）----
let fixdir = find_path('test/fixtures/snapshot-v101/' + OLDID);
if (fixdir == null) {
	fail++;
	printf("FAIL  找不到 fixture（cwd=%s）\n", fs.getcwd());
}
else {
	copy_tree(fixdir, SNAPS + '/' + OLDID);
	ok("fixture 已就位（4 个文件）", length(fs.lsdir(SNAPS + '/' + OLDID)) == 4);

	// ---- 1. 读旧快照（C3 的判据）----
	let ls = snapshot.list(OPTS);
	eq("list 读到 1 份旧快照", length(ls), 1);
	eq("旧快照 id", ls[0].id, OLDID);
	eq("旧快照 mode（读的是 mode 文件）", ls[0].mode, "on");
	eq("旧快照的上游首项（取第一条 list server）", ls[0].upstream, "172.16.1.2");

	// ---- 2. restore：把旧快照还原到假环境 ----
	state.open({ confdir: CONF });
	fs.writefile(DHCP, "config dnsmasq\n\toption port '9999'\n");   // 现状与快照不同

	let called = 0;
	let opts_restore = {
		_snapdir: SNAPS, _dhcp: DHCP, _frag: FRAG, confdir: CONF,
		skip_reload: true, skip_verify: true,
		onFn: function () { called++; }
	};
	let r = snapshot.restore(OLDID, opts_restore);
	eq("restore ok", r.ok, true);
	eq("restore 回的 id", r.id, OLDID);

	let dhcp_now = fs.readfile(DHCP);
	ok("dhcp 被还原成快照内容（含 dnsmasq 段）", match(dhcp_now, /list server '172\.16\.1\.2'/) != null);
	ok("现状里的旧端口 9999 已被覆盖", match(dhcp_now, /9999/) == null);

	eq("mode 还原成 on", state.get_opt('dns_switch', 'settings', 'mode'), "on");
	eq("settings 回灌：adh_ip", state.get_opt('dns_switch', 'settings', 'adh_ip'), "172.16.1.2");
	eq("settings 回灌：adh_mac（这条最容易被漏）",
		state.get_opt('dns_switch', 'settings', 'adh_mac'), "aa:bb:cc:dd:ee:ff");
	eq("settings 回灌：dot853", state.get_opt('dns_switch', 'settings', 'dot853'), "allow");

	ok("nft 片段被还原", fs.readfile(FRAG) != null);
	ok("还原的片段含 dns_hijack", match(fs.readfile(FRAG), /chain dns_hijack/) != null);

	// ---- 3. onFn：mode=on 必须回调（且只回调一次）----
	eq("mode=on 时 onFn 被回调 1 次", called, 1);

	// ---- 4. mode≠on 时**不许**回调 ----
	// 造一份 mode=off 的快照
	let offid = '20261124-090000';
	copy_tree(fixdir, SNAPS + '/' + offid);
	fs.writefile(SNAPS + '/' + offid + '/mode', "off\n");
	fs.writefile(SNAPS + '/' + offid + '/dns_switch.uci',
		"dns_switch.settings.mode='off'\ndns_switch.settings.adh_ip='10.0.0.9'\n");

	called = 0;
	let r2 = snapshot.restore(offid, opts_restore);
	eq("mode=off 的 restore ok", r2.ok, true);
	eq("mode=off 时 onFn **不**被回调", called, 0);
	eq("mode 被改成 off", state.get_opt('dns_switch', 'settings', 'mode'), "off");
	eq("settings 跟着换成快照里的值", state.get_opt('dns_switch', 'settings', 'adh_ip'), "10.0.0.9");

	// ---- 5. 回滚不存在的快照 → E_NOT_FOUND ----
	let r3 = snapshot.restore('19990101-000000', opts_restore);
	eq("不存在的快照 → ok=false", r3.ok, false);
	eq("不存在的快照 → E_NOT_FOUND", r3.code, "E_NOT_FOUND");

	// ---- 6. diff：两份一样的快照 → "没有差别" ----
	let dtext = snapshot.diff(OLDID, offid, OPTS);
	ok("diff 差异文本里点名了有差异的文件", match(dtext, /=== (mode|dhcp|dns_switch\.uci) ===/) != null);
	copy_tree(SNAPS + '/' + OLDID, SNAPS + '/20261124-100000');
	let dtext2 = snapshot.diff(OLDID, '20261124-100000', OPTS);
	ok("两份完全相同 → 没有差别", match(dtext2, /两份快照没有差别/) != null);

	// ---- 7. prune：只留 10 份 ----
	for (let i = 0; i < 12; i++) {
		copy_tree(fixdir, SNAPS + sprintf('/20200101-%06d', i));   // 必须比"今天"旧，否则 save 后的 prune 会把刚存的当最旧删掉
	}
	let before = length(snapshot.list(OPTS));
	let pr = snapshot.prune(OPTS);
	eq("prune ok", pr.ok, true);
	ok("prune 前超过 10 份", before > 10);
	eq("prune 后正好 10 份", length(snapshot.list(OPTS)), 10);
	ok("留下的都是较新的（2020 那批最老的被删了）", fs.stat(SNAPS + '/20200101-000000') == null);
}

// ---- 8. save：目录结构与 v1.0.1 一致（C7）----
mkdir_p(DHCP);
fs.writefile(DHCP, "config dnsmasq\n\tlist server '1.1.1.1'\n");
fs.writefile(FRAG, "chain dns_hijack {\n}\n");
state.open({ confdir: CONF });
let sv = snapshot.save({ _snapdir: SNAPS, _dhcp: DHCP, _frag: FRAG, confdir: CONF });
eq("save ok", sv.ok, true);
ok("save 返回时间戳 id（形如 YYYYMMDD-HHMMSS）",
	type(sv.id) == "string" && match(sv.id, /^[0-9]{8}-[0-9]{6}$/) != null);
let sdir = SNAPS + '/' + sv.id;
for (let i = 0; i < 4; i++) {
	let f = [ 'dhcp', 'hijack.nft', 'dns_switch.uci', 'mode' ][i];
	ok("快照里有 " + f + "（C7 的目录结构）", fs.readfile(sdir + '/' + f) != null);
}
eq("save 后 mode 文件内容跟着配置", trim(fs.readfile(sdir + '/mode')), "off");

// ---- 9. 收尾自清 ----
wipe(BASE); fs.rmdir(BASE);
eq("收尾：临时目录已删除", fs.stat(BASE), null);

printf("\n%s: %d passed, %d failed\n", "snapshot_test", pass, fail);
exit(fail == 0 ? 0 : 1);
