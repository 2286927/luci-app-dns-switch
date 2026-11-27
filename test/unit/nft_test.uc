'use strict';

// ============================================================
// nft_test.uc —— nft.uc 单测
//
// 跑法（设备上，源码树内任意目录）：ucode test/unit/nft_test.uc
// 断言失败 → 退出码 1。
//
// 重点：**build() 的 4 组输出与 test/golden/*.nft 逐字节一致**（G1 的判据在这里
// 先跑一遍，比 nft_golden.sh 更早暴露问题）。不一致时打印首个差异行，不只报 false。
//
// 安全：purge() 的 force 分支会真的 `nft delete chain`，**绝不拿真机防火墙试**。
// 用 opts.nft 指到一个假 nft 脚本 + 假 nftdir 目录，只验逻辑与幂等性。
// ============================================================

import * as nft from '../../luci-app-dns-switch/root/usr/libexec/dns-switch/nft.uc';

let fs = require('fs');

const BASE = '/tmp/ds-v11/ut-nft';
const MAC = 'aa:bb:cc:dd:ee:ff';

let pass = 0;
let fail = 0;

// 注意：ucode 的 type(null) 返回 null 本身（不是字符串 "null"），判空一律 === null
function show(v) {
	let t = type(v);
	if (t === null) return "null";
	if (t == 'string') return "'" + v + "'";
	if (t == 'int') return sprintf("%d", v);
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

// 逐行比对，不一致时报出**第一处**差异（整份 908 字节全打印会淹掉日志）
function eq_text(name, got, want) {
	if (got === want) { pass++; print("PASS  " + name + "\n"); return; }
	fail++;
	printf("FAIL  %s\n      got  %d 字节 / want %d 字节\n", name, length(got), length(want));
	let g = split(got, '\n');
	let w = split(want, '\n');
	let n = (length(g) < length(w)) ? length(g) : length(w);
	for (let i = 0; i < n; i++) {
		if (g[i] !== w[i]) {
			printf("      第一处差异在第 %d 行：\n        got =%s\n        want=%s\n",
				i + 1, show(g[i]), show(w[i]));
			return;
		}
	}
	printf("      前 %d 行相同，差异在长度（少/多了尾部内容）\n", n);
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

// ucode 拿不到本脚本路径（ARGV 只有额外参数），从 cwd 逐级往上找 fixture
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

wipe(BASE); fs.rmdir(BASE);
mkdir_p(BASE);

// ---- 1. build() 4 组与 golden 逐字节一致（G1 的判据提前在这里跑）----
let golddir = find_path('test/golden');
if (golddir == null) {
	fail++;
	printf("FAIL  找不到 test/golden（cwd=%s，请在源码树内运行）\n", fs.getcwd());
}
else {
	let cases = [
		[ 'allow', '',        'nft-allow-nomac.nft' ],
		[ 'allow', MAC,       'nft-allow-mac.nft' ],
		[ 'block', '',        'nft-block-nomac.nft' ],
		[ 'block', MAC,       'nft-block-mac.nft' ]
	];
	for (let i = 0; i < length(cases); i++) {
		let want = fs.readfile(golddir + '/' + cases[i][2]);
		eq_text(sprintf("build(%s,%s) 与 %s 逐字节一致",
			show(cases[i][0]), (length(cases[i][1]) ? 'MAC' : '空'),
			cases[i][2]), nft.build(cases[i][0], cases[i][1]), want);
	}

	// 尾部换行：少一个 \n 就是 908→907，G1 直接红
	ok("build 结果以单个 \\n 结尾（allow）", match(nft.build('allow', ''), /[^\n]\n$/) != null);
	ok("build 结果以单个 \\n 结尾（block+mac）", match(nft.build('block', MAC), /[^\n]\n$/) != null);
	ok("build 结果不以空行结尾", match(nft.build('block', MAC), /\n\n$/) == null);

	// 行数也要对得上（能抓到"多写一条/少写一条规则"）
	eq("allow+nomac 行数", length(split(nft.build('allow', ''), '\n')), 14);
	eq("allow+mac 行数", length(split(nft.build('allow', MAC), '\n')), 16);
	eq("block+nomac 行数", length(split(nft.build('block', ''), '\n')), 24);
	eq("block+mac 行数", length(split(nft.build('block', MAC), '\n')), 28);
}

// ---- 2. 纯函数：同一入参两次调用结果相同 ----
eq("两次 build 结果相同", nft.build('block', MAC), nft.build('block', MAC));

// ---- 3. dot853 只认 'block'，其它一律 allow（与 v1.0.1 的 `=` 判断一致）----
eq("dot853='nonsense' 按 allow 处理", nft.build('nonsense', ''), nft.build('allow', ''));
eq("dot853='' 按 allow 处理", nft.build('', ''), nft.build('allow', ''));
eq("dot853='BLOCK' 大小写敏感，按 allow",
	nft.build('BLOCK', ''), nft.build('allow', ''));

// ---- 4. 可选的第三个参数 adh（默认值必须与 golden 一致）----
ok("两参调用用默认 172.16.1.2", match(nft.build('allow', ''), /ip saddr 172\.16\.1\.2 /) != null);
ok("给了 adh 就用给的值", match(nft.build('allow', '', '10.0.0.9'), /ip saddr 10\.0\.0\.9 /) != null);
ok("给了 adh 后不再出现 172.16.1.2", match(nft.build('allow', '', '10.0.0.9'), /172\.16\.1\.2/) == null);
ok("adh 对 853 段同样生效",
	match(nft.build('block', '', '10.0.0.9'), /ip saddr 10\.0\.0\.9 tcp dport 853 accept/) != null);

// ---- 5. write()：字节数 / sha256 / 落盘内容 ----
let wp = BASE + '/frag.nft';
let w = nft.write(wp, 'block', MAC);
eq("write ok", w.ok, true);
eq("write 回报 path", w.path, wp);
eq("write 回报字节数 = 落盘文件大小", w.bytes, fs.stat(wp).size);
ok("write 回报 sha256 非空", type(w.sha256) == "string" && length(w.sha256) == 64);
eq("落盘内容与 build 一致", fs.readfile(wp), nft.build('block', MAC));

// ---- 6. check()：必须包 table，裸片段会报 syntax error ----
let ck = nft.check(wp);
eq("check 合法片段 ok", ck.ok, true);
fs.writefile(BASE + '/bad.nft', "chain oops {\n\tthis is not nft syntax\n}\n");
let ck2 = nft.check(BASE + '/bad.nft');
eq("check 非法片段 ok=false", ck2.ok, false);
ok("check 失败带 nft 的原始报错", type(ck2.message) == "string" && length(ck2.message) > 0);
let ck3 = nft.check(BASE + '/no-such-file.nft');
eq("check 读不到文件 → ok=false", ck3.ok, false);

// ---- 7. purge()：block 策略下不动；force 走假 nft，验逻辑与幂等 ----
let pb = nft.purge('block');
eq("purge('block') ok", pb.ok, true);
eq("purge('block') 不动链", pb.removed, false);

// 假 nft：状态文件在 = "链存在"，delete 时删状态文件并记账
let fake = BASE + '/fake-nft';
let state_f = BASE + '/fake-state';
let log_f = BASE + '/fake-log';
fs.writefile(fake, join('\n', [
	"#!/bin/sh",
	"case \"$1\" in",
	"  list) [ -f " + state_f + " ] && { echo 'chain dot_block {'; echo '}'; exit 0; }; exit 1 ;;",
	"  delete) rm -f " + state_f + "; echo deleted >> " + log_f + "; exit 0 ;;",
	"esac",
	"exit 0",
	""
]));
fs.chmod(fake, 0o755);
let emptydir = BASE + '/nftd';
mkdir_p(emptydir);
let opts = { nft: fake, nftdir: emptydir };

fs.writefile(state_f, "1");
let p1 = nft.purge('force', opts);
eq("链在时 purge(force) ok", p1.ok, true);
eq("链在时 purge(force) removed=true", p1.removed, true);
eq("delete 真的被调了一次", type(fs.readfile(log_f)) == "string", true);

let p2 = nft.purge('force', opts);
eq("第二次 purge(force) ok（幂等）", p2.ok, true);
eq("第二次 removed=false（链已不在）", p2.removed, false);

// ---- 8. sync()：漂移修补（落点走 opts.frag，绝不写 /etc/nftables.d）----
let sy = BASE + '/sync.nft';
let cfg_allow = { ok: true, settings: { dot853: 'allow', adh_mac: '', adh_ip: '172.16.1.2' } };

eq("sync 在 cfg.ok=false 时拒绝", nft.sync({ ok: false }).code, "E_INTERNAL");
eq("sync 在 cfg 为 null 时拒绝", nft.sync(null).code, "E_INTERNAL");

let s1 = nft.sync(cfg_allow, { frag: sy });
eq("sync 文件不存在 → ok", s1.ok, true);
eq("sync 文件不存在 → changed=true", s1.changed, true);
eq("sync 回报 dot", s1.dot, "allow");
eq("sync 落盘内容 = build('allow','')", fs.readfile(sy), nft.build('allow', ''));

let s2 = nft.sync(cfg_allow, { frag: sy });
eq("sync 内容已一致 → ok", s2.ok, true);
eq("sync 内容已一致 → changed=false", s2.changed, false);

fs.writefile(sy, "# 手工改坏的内容\n");
let s3 = nft.sync(cfg_allow, { frag: sy });
eq("sync 发现漂移 → changed=true", s3.changed, true);
eq("sync 把漂移改回来", fs.readfile(sy), nft.build('allow', ''));

let cfg_block_adh = { ok: true, settings: { dot853: 'block', adh_mac: MAC, adh_ip: '10.0.0.9' } };
let s4 = nft.sync(cfg_block_adh, { frag: sy });
eq("sync 跟随 dot853=block", s4.dot, "block");
eq("sync 跟随 adh_ip（不是写死 172.16.1.2）", fs.readfile(sy), nft.build('block', MAC, '10.0.0.9'));

// ---- 9. present()：只读，只回形状 ----
let pr = nft.present();
eq("present().hijack 是 bool", type(pr.hijack), "bool");
eq("present().ether 是 int", type(pr.ether), "int");
eq("present().dot_block 是 bool", type(pr.dot_block), "bool");

// ---- 9. 收尾自清 ----
wipe(BASE); fs.rmdir(BASE);
eq("收尾：临时目录已删除", fs.stat(BASE), null);

printf("\n%s: %d passed, %d failed\n", "nft_test", pass, fail);
exit(fail == 0 ? 0 : 1);
