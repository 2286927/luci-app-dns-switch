'use strict';

// ============================================================
// dnsmasq_test.uc —— dnsmasq.uc 单测
//
// 跑法（设备上，源码树内任意目录）：ucode test/unit/dnsmasq_test.uc
//
// 全部写操作都在**临时 confdir** 里做，绝不碰 /etc/config。
// 唯一会碰现场的 rollback() 只断言"存在且是函数"——它的完整路径由 QEMU 的
// A6/A8 覆盖（会重启 dnsmasq、覆盖 /etc/config/dhcp）。
// ============================================================

import * as state from '../../luci-app-dns-switch/root/usr/libexec/dns-switch/state.uc';
import * as dnsmasq from '../../luci-app-dns-switch/root/usr/libexec/dns-switch/dnsmasq.uc';

let fs = require('fs');

const BASE = '/tmp/ds-v11/ut-dnsmasq';
const CONF = BASE + '/dns_switch';
const DHCP = BASE + '/dhcp';

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
		let st = fs.stat(p);
		if (st != null && st.type == 'directory') { wipe(p); fs.rmdir(p); }
		else fs.unlink(p);
	}
}

wipe(BASE); fs.rmdir(BASE);
mkdir_p(BASE);
fs.writefile(DHCP, "config dnsmasq\n\toption port '53'\n\nconfig dhcp 'lan'\n\toption interface 'lan'\n");

// ---- 0. 先 open 一个临时 confdir（state 是单例，dnsmasq 全靠它）----
let o = state.open({ confdir: BASE });
eq("state.open 临时 confdir ok", o.ok, true);

// ---- 1. set_upstream：list 写入 + 三个标志位 ----
let r = dnsmasq.set_upstream([ '1.1.1.1', '8.8.8.8' ]);
eq("set_upstream ok", r.ok, true);
eq("set_upstream changed=true", r.changed, true);

let txt = fs.readfile(DHCP);
ok("server 写成 uci list（不是标量）", match(txt, /list server '1\.1\.1\.1'/) != null);
ok("第二条也在", match(txt, /list server '8\.8\.8\.8'/) != null);
ok("noresolv=1 落盘", match(txt, /option noresolv '1'/) != null);
ok("strictorder=1 落盘", match(txt, /option strictorder '1'/) != null);
ok("dns_redirect=0 落盘", match(txt, /option dns_redirect '0'/) != null);
eq("读回来是 2 条", join(',', state.get_list('dhcp', '@dnsmasq[0]', 'server')), "1.1.1.1,8.8.8.8");

r = dnsmasq.set_upstream([ '1.1.1.1', '8.8.8.8' ]);
eq("同值再写 → changed=false（不重复写盘）", r.changed, false);

r = dnsmasq.set_upstream([]);
eq("空列表被拒（E_ARG）", r.code, "E_ARG");
eq("被拒后 server 没被清空", length(state.get_list('dhcp', '@dnsmasq[0]', 'server')), 2);

r = dnsmasq.set_upstream([ '1.1.1.1' ], { v6: [ '2400::1' ] });
eq("v6 追加进同一个 list", join(',', state.get_list('dhcp', '@dnsmasq[0]', 'server')), "1.1.1.1,2400::1");

// ---- 2. set_option6：必须合成单条 `6,a,b` ----
r = dnsmasq.set_option6([ '172.16.1.1' ]);
eq("set_option6 ok", r.ok, true);
eq("合成单条 option 6", join(',', state.get_list('dhcp', 'lan', 'dhcp_option')), "6,172.16.1.1");

r = dnsmasq.set_option6([ '172.16.1.1' ]);
eq("同值 → changed=false", r.changed, false);

r = dnsmasq.set_option6([ '172.16.1.1', '9.9.9.9' ]);
eq("多地址仍是一条（逗号拼）", join(',', state.get_list('dhcp', 'lan', 'dhcp_option')), "6,172.16.1.1,9.9.9.9");
eq("只有一条 dhcp_option", length(state.get_list('dhcp', 'lan', 'dhcp_option')), 1);

// 不相关的 dhcp_option 必须保留（v1.0.1 的 strip_opt 只剥 ^6）
state.set_opt('dhcp', 'lan', 'dhcp_option', [ '3,172.16.1.1', '6,1.1.1.1' ]);
state.commit('dhcp');
dnsmasq.set_option6([ '172.16.1.1' ]);
eq("只剥 6 那条、保留 3 那条",
	join(',', state.get_list('dhcp', 'lan', 'dhcp_option')), "3,172.16.1.1,6,172.16.1.1");

// ---- 3. set_rdnss ----
r = dnsmasq.set_rdnss([ '2400::1', '2401::1' ]);
eq("set_rdnss ok", r.ok, true);
eq("RDNSS 写成 list", join(',', state.get_list('dhcp', 'lan', 'dns')), "2400::1,2401::1");
r = dnsmasq.set_rdnss([ '2400::1', '2401::1' ]);
eq("RDNSS 同值 → changed=false", r.changed, false);
r = dnsmasq.set_rdnss([]);
eq("RDNSS 空数组 = 清空", length(state.get_list('dhcp', 'lan', 'dns')), 0);

// ---- 4. pointers（只读）----
dnsmasq.set_upstream([ '10.0.0.9' ]);
let p = dnsmasq.pointers();
eq("pointers.first = 上游第一条", p.first, "10.0.0.9");
eq("pointers.port = 53（配置里是 53）", p.port, 53);
eq("pointers 类型是 int", type(p.port), "int");

// ---- 5. 钉子：commit 错包会被发现（lead 明确要求）----
// 写 dhcp 的 server 后只 commit('dns_switch')，dhcp 文件**不应**出现新值
state.set_opt('dhcp', '@dnsmasq[0]', 'server', [ '7.7.7.7' ]);
let wrong = state.commit();                 // 缺省 = dns_switch
eq("commit()（缺省 dns_switch）返回 ok", wrong.ok, true);
ok("但 dhcp 文件里**没有** 7.7.7.7（错包提交不落盘）",
	match(fs.readfile(DHCP), /7\.7\.7\.7/) == null);

let right = state.commit('dhcp');
eq("commit('dhcp') 返回 ok", right.ok, true);
ok("commit('dhcp') 之后 7.7.7.7 才落盘",
	match(fs.readfile(DHCP), /7\.7\.7\.7/) != null);

// ---- 6. verify 不产生 E_*（失败只是业务结论）----
let v = dnsmasq.verify('invalid.invalid', { tries: 1 });
eq("verify 回 ok/ms/reason", type(v.ok), "bool");
eq("解析不存在的域名 → ok=false", v.ok, false);
ok("verify 的 reason 非空", length(v.reason) > 0);
eq("verify **不带** code 字段（不产生 E_*）", v.code, null);

// ---- 7. rollback 只断言存在（真跑会重启 dnsmasq、覆盖 /etc/config/dhcp）----
eq("rollback 是函数", type(dnsmasq.rollback), "function");

// ---- 8. 收尾自清 ----
wipe(BASE); fs.rmdir(BASE);
eq("收尾：临时目录已删除", fs.stat(BASE), null);

printf("\n%s: %d passed, %d failed\n", "dnsmasq_test", pass, fail);
exit(fail == 0 ? 0 : 1);
