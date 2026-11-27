'use strict';

// ============================================================
// snapshot.uc —— L2：快照（存/列/回滚/比对/修剪）
// 承接 v1.0.1 snap_save/snap_list/snap_apply_settings/snap_restore/snap_diff。
// 格式与 v1.0.1 一致（C3/C7）：`<ts>/{dhcp,hijack.nft,dns_switch.uci,mode}`。
// restore 顺序硬要求：还原 mode+settings → nft → reload → **才** onFn（错序=假回滚）。
// onFn 是功能参；`_` 前缀三个 + skip_* 才是测试缝。state 依赖因回滚要写 uci（U25）。
// ============================================================

import * as config from './config.uc';
import * as nft from './nft.uc';
import * as state from './state.uc';
import { log, ev } from './log.uc';
import { runq } from './sh.uc';

let fs = require('fs');

const SNAPDIR = '/etc/dns-switch/snapshots';
const DHCP = '/etc/config/dhcp';
const FRAG = '/etc/nftables.d/20-dns-hijack.nft';
const KEEP = 10;
const FILES = [ 'dhcp', 'hijack.nft', 'dns_switch.uci', 'mode' ];

// ---------- 工具（必须定义在使用者之前：ucode 函数不提升，N27）----------

function opt_of(opts, key, dflt) {
	if (opts != null && type(opts) == 'object') {
		let v = opts[key];
		if (type(v) == 'string' && length(v)) return v;
	}
	return dflt;
}

// 以下三个是**测试缝**（下划线前缀自证），生产不传
function dir_of(opts)  { return opt_of(opts, '_snapdir', SNAPDIR); }
function dhcp_of(opts) { return opt_of(opts, '_dhcp', DHCP); }
function frag_of(opts) { return opt_of(opts, '_frag', FRAG); }

// 与 v1.0.1 同源（date）；不用 localtime()，其字段名跨版本不一致。
function stamp() {
	let r = runq('date +%Y%m%d-%H%M%S');
	let v = trim(r.out);
	if (r.rc == 0 && match(v, /^[0-9]{8}-[0-9]{6}$/) != null) return v;
	return sprintf('%d', time());     // 兜底：至少不重名
}

function read_text(p) {
	let t = fs.readfile(p);
	return (type(t) == 'string') ? t : null;
}

function mkdir_p(path) {
	if (type(path) != 'string' || !length(path) || path == '/') return true;
	let st = fs.stat(path);
	if (st != null && st.type == 'directory') return true;
	let parent = fs.dirname(path);
	if (parent != path) mkdir_p(parent);
	if (fs.mkdir(path) === true) return true;
	st = fs.stat(path);
	return (st != null && st.type == 'directory');
}

function rm_rf(path) {
	let st = fs.lstat(path);
	if (st == null) return true;
	if (st.type == 'link') return fs.unlink(path) != null;
	if (st.type != 'directory') return fs.unlink(path) != null;
	let names = fs.lsdir(path);
	if (type(names) == 'array') {
		for (let i = 0; i < length(names); i++) {
			if (names[i] == '.' || names[i] == '..') continue;
			rm_rf(path + '/' + names[i]);
		}
	}
	return fs.rmdir(path) != null;
}

function sorted_names(dir) {
	let names = fs.lsdir(dir);
	if (type(names) != 'array') return [];
	let out = [];
	for (let i = 0; i < length(names); i++) {
		if (names[i] == '.' || names[i] == '..') continue;
		push(out, names[i]);
	}
	return sort(out);
}

// 上游首项：第一条 `list server 'x'` 的地址去引号（旧快照同形，C3）。
function upstream_first(dhcp_text) {
	if (type(dhcp_text) != 'string') return '';
	let lines = split(dhcp_text, '\n');
	for (let i = 0; i < length(lines); i++) {
		let f = [];
		let raw = split(trim(lines[i]), ' ');
		for (let j = 0; j < length(raw); j++) if (length(raw[j])) push(f, raw[j]);
		if (length(f) >= 3 && f[0] == 'list' && f[1] == 'server') {
			return replace(f[2], /'/g, '');
		}
	}
	return '';
}

// 解析 `uci show dns_switch` 的形态：`dns_switch.settings.key='value'`
// list 会写成 `'a' 'b'` → 这里把 `' '` 合回空格（v1.0.1 就是这么做的）。
function settings_pairs(uci_text) {
	let out = [];
	if (type(uci_text) != 'string') return out;
	let lines = split(uci_text, '\n');
	for (let i = 0; i < length(lines); i++) {
		let m = match(lines[i], /^dns_switch\.settings\.([A-Za-z0-9_]+)='(.*)'$/);
		if (m == null) continue;
		let v = replace(m[2], /' '/g, ' ');
		push(out, { key: m[1], val: replace(v, /'/g, '') });
	}
	return out;
}

// 复刻 `uci show` 的单行格式（不 spawn `uci show`：那会被 A5 判成经 shell 调 uci）。
function uci_text_of(cfg) {
	let ks = [ 'mode', 'adh_ip', 'adh_port', 'fallback_dns', 'fallback_dns6',
		'probe_domain', 'adh_mac', 'dot853', 'upstream_mode', 'isp_list4', 'isp_list6' ];
	let out = [ "dns_switch.settings=dns_switch" ];
	for (let i = 0; i < length(ks); i++) {
		let v = cfg.settings[ks[i]];
		push(out, sprintf("dns_switch.settings.%s='%s'", ks[i], (v == null) ? '' : v));
	}
	return join('\n', out) + '\n';
}

function fail(code, message) {
	log(message);
	return { ok: false, code: code, message: message, detail: {} };
}

// ---------- 导出 ----------

/** 只留最近 KEEP 份。返回 { ok, removed }。 */
export function prune(opts) {
	let dir = dir_of(opts);
	let names = sorted_names(dir);
	let removed = 0;
	while (length(names) > KEEP) {
		rm_rf(dir + '/' + names[0]);
		names = sorted_names(dir);
		removed++;
	}
	return { ok: true, removed: removed };
}

/** 存一份快照。返回 { ok, id }（id=时间戳）。非幂等：每次新建目录。 */
export function save(opts) {
	let dir = dir_of(opts);
	if (!mkdir_p(dir)) return fail('E_INTERNAL', sprintf('建不了快照目录：%s', dir));

	let ts = stamp();
	let d = dir + '/' + ts;
	if (!mkdir_p(d)) return fail('E_INTERNAL', sprintf('建不了快照目录：%s', d));

	let dhcp = read_text(dhcp_of(opts));
	if (dhcp != null) fs.writefile(d + '/dhcp', dhcp);

	let frag = read_text(frag_of(opts));
	if (frag != null) fs.writefile(d + '/hijack.nft', frag);

	let cfg = config.load(opts);
	if (cfg.ok != true) return fail('E_INTERNAL', '配置读不到，快照内容会不完整');
	fs.writefile(d + '/dns_switch.uci', uci_text_of(cfg));
	fs.writefile(d + '/mode', cfg.settings.mode + '\n');

	prune(opts);
	log(sprintf('已备份到 %s', dir));
	return { ok: true, id: ts };
}

/** 列快照（新→旧）。返回 [{id, mode, upstream}]，渲染由 CLI 负责（C4 的对齐在那边）。 */
export function list(opts) {
	let dir = dir_of(opts);
	let names = sorted_names(dir);
	let out = [];
	for (let i = length(names) - 1; i >= 0; i--) {
		let d = dir + '/' + names[i];
		if (fs.stat(d) == null) continue;
		let m = read_text(d + '/mode');
		m = (type(m) == 'string') ? trim(m) : '';
		push(out, {
			id: names[i],
			mode: length(m) ? m : '?',
			upstream: upstream_first(read_text(d + '/dhcp'))
		});
	}
	return out;
}

/** 回滚到 id。顺序：dhcp → mode → settings → nft → reload → onFn。 */
export function restore(id, opts) {
	let dir = dir_of(opts);
	let d = dir + '/' + id;
	if (fs.stat(d) == null) return fail('E_NOT_FOUND', sprintf('没有这个快照：%s', id));

	let dhcp_saved = read_text(d + '/dhcp');
	if (dhcp_saved == null) return fail('E_NOT_FOUND', sprintf('快照不完整，缺 dhcp：%s', id));

	if (fs.writefile(dhcp_of(opts), dhcp_saved) == null) {
		return fail('E_INTERNAL', '还原 dhcp 失败');
	}
	let c1 = state.commit('dhcp');
	if (!c1.ok) return fail('E_UCI_COMMIT', c1.message);

	let m = read_text(d + '/mode');
	m = (type(m) == 'string') ? trim(m) : '';
	if (length(m)) {
		state.set_setting('mode', m);
		let c2 = state.commit();
		if (!c2.ok) return fail('E_UCI_COMMIT', c2.message);
	}

	// settings 必须一起还原，否则 onFn 会用当前（要逃离的）那套参数重下发。
	let pairs = settings_pairs(read_text(d + '/dns_switch.uci'));
	for (let i = 0; i < length(pairs); i++) {
		state.set_setting(pairs[i].key, pairs[i].val);
	}
	if (length(pairs)) {
		let c3 = state.commit();
		if (!c3.ok) return fail('E_UCI_COMMIT', c3.message);
	}

	let frag_saved = read_text(d + '/hijack.nft');
	if (frag_saved != null) fs.writefile(frag_of(opts), frag_saved);
	else fs.unlink(frag_of(opts));
	runq('/usr/sbin/nft delete chain inet fw4 dns_hijack');
	runq('/usr/sbin/nft delete table inet dnsmasq');

	if (opts == null || opts.skip_reload != true) {
		runq('/sbin/fw4 reload');
		runq('/etc/init.d/dnsmasq restart');
	}

	// 意图是 on 就必须按还原后的参数再下发一次（否则 option6/RDNSS 会缺）
	let cfg2 = config.load(opts);
	if (cfg2.ok == true && cfg2.settings.mode == 'on' && opts != null && type(opts.onFn) == 'function') {
		opts.onFn();
	}

	if (opts == null || opts.skip_verify != true) {
		let v = runq('nslookup www.baidu.com 127.0.0.1');
		if (v.rc != 0) {
			log(sprintf('快照回滚到 %s，但解析失败', id));
			return fail('E_INTERNAL', '已回滚配置，但解析仍失败。先执行 dns-switch rescue');
		}
	}

	state.set_status('last_change', "" + time());
	state.commit();
	ev('snapshot', sprintf('已回滚到快照 %s', id), '解析正常');
	log(sprintf('快照回滚到 %s', id));
	return { ok: true, id: id };
}

/**
 * 比对两份快照，返回**文本**（C4 要逐字节比，所以这里直接出文本）。
 * 时间戳归一化由调用方/门禁负责。
 */
export function diff(a, b, opts) {
	let dir = dir_of(opts);
	let da = dir + '/' + a;
	let db = dir + '/' + b;
	if (fs.stat(da) == null) return sprintf('没有这个快照：%s\n用 dns-switch snapshot 看现有列表\n', a);
	if (fs.stat(db) == null) return sprintf('没有这个快照：%s\n用 dns-switch snapshot 看现有列表\n', b);

	let out = [ sprintf('旧：%s', a), sprintf('新：%s', b), "" ];
	let n = 0;
	for (let i = 0; i < length(FILES); i++) {
		let f = FILES[i];
		let ta = read_text(da + '/' + f);
		let tb = read_text(db + '/' + f);
		if (ta == null && tb == null) continue;
		if (ta === tb) continue;
		n++;
		push(out, sprintf('=== %s ===', f));
		push(out, sprintf('旧 %s 字节 / 新 %s 字节',
			(ta == null) ? '(缺)' : ("" + length(ta)),
			(tb == null) ? '(缺)' : ("" + length(tb))));
		push(out, "");
	}
	if (n == 0) push(out, '两份快照没有差别。');
	return join('\n', out) + '\n';
}
