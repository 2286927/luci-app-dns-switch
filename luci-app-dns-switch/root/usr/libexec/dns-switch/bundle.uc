'use strict';

// ============================================================
// bundle.uc —— L3：诊断包（把"现场那一刻"拼成一份可贴给别人的文本）
//
// C6 要求**逐字节稳定**：字段顺序、缩进、换行固定；同一 now 两次生成必须相同。
// 所以 `collect/render` 都接受 `{now}`（epoch 秒）**由调用方注入**，缺省取当前时间。
// 时间只以 `生成时间 <epoch>` 一行的形式出现（固定位置、固定写法）——
// 不格式化、不带本地时区，否则两次生成必然不同，"稳定"就没了。
//
// 只有一处 spawn：默认文件名用 `date -d @<now>`。它由 now 决定，所以同 now 同名字；
// 而内容完全不含它的输出。
//
// 依赖：status + timeline + config + sh + fs
// （SPEC 写的是 `status, config, sh`——timeline 是后加的真实依赖：
//   诊断包必须含事件时间线，而时间线的渲染器在 timeline.uc，不抄第二份。）
// ============================================================

import * as status from './status.uc';
import * as timeline from './timeline.uc';
import * as config from './config.uc';
import { runq } from './sh.uc';

let fs = require('fs');

const FRAG = '/etc/nftables.d/20-dns-hijack.nft';
const EVENTS = '/etc/dns-switch/events.log';
const TIME_EVENTS = 20;

function opt_of(opts, key, dflt) {
	if (opts != null && type(opts) == 'object') {
		let v = opts[key];
		if (type(v) == 'string' && length(v)) return v;
		if (type(v) == 'int') return v;
	}
	return dflt;
}

function now_of(opts) {
	let n = opt_of(opts, 'now', null);
	return (n != null) ? n : time();
}

function read_or(p, missing) {
	let t = fs.readfile(p);
	return (type(t) == 'string') ? t : missing;
}

// 文件名里的时间戳（由 now 决定，同 now 同名）
function stamp(now, opts) {
	let forced = opt_of(opts, 'stamp', null);
	if (type(forced) == 'string' && length(forced)) return forced;
	let r = runq(sprintf('date -d @%d "+%%Y%%m%%d-%%H%%M%%S"', now));
	let v = trim(r.out);
	return (r.rc == 0 && length(v)) ? v : ("" + now);
}

function settings_dump(cfg) {
	if (cfg == null || cfg.ok != true) return '(配置读不到)\n';
	let ks = [ 'mode', 'adh_ip', 'adh_port', 'fallback_dns', 'fallback_dns6',
		'probe_domain', 'adh_mac', 'dot853', 'upstream_mode', 'isp_list4', 'isp_list6' ];
	let L = [];
	for (let i = 0; i < length(ks); i++) {
		let v = cfg.settings[ks[i]];
		push(L, sprintf('dns_switch.settings.%s=%s', ks[i], (v == null) ? '' : v));
	}
	return join('\n', L) + '\n';
}

/**
 * 生成诊断文本。**同一 now 两次调用必须逐字节相同**（C6）。
 * opts: { now, confdir?_ , events_path?, frag_path? } —— 后三个是测试缝。
 */
export function render(opts) {
	let now = now_of(opts);
	let L = [];

	push(L, "# dns-switch 诊断包");
	push(L, sprintf("生成时间 %d", now));
	push(L, "");

	push(L, "== status ==");
	// status.collect 需要 confdir（测试缝透传）
	let so = (opts != null && type(opts) == 'object' && type(opts.confdir) == 'string')
		? { confdir: opts.confdir } : null;
	push(L, trim(status.render_text(status.collect(so))));
	push(L, "");

	push(L, "== 事件时间线 ==");
	let eo = { path: opt_of(opts, 'events_path', EVENTS) };
	let tl = timeline.render(TIME_EVENTS, eo);
	push(L, trim(tl));
	push(L, "");

	push(L, "== nft 片段 ==");
	let frag = read_or(opt_of(opts, 'frag_path', FRAG), '');
	if (!length(frag)) push(L, '(片段不存在)');
	else push(L, trim(frag));
	push(L, "");

	push(L, "== 已解析配置 ==");
	let co = (opts != null && type(opts) == 'object' && type(opts.confdir) == 'string')
		? { confdir: opts.confdir } : null;
	push(L, trim(settings_dump(config.load(co))));

	return join('\n', L) + '\n';
}

/**
 * 落盘并回报 { ok, path, size }。`size` 是**文本字节数**（不含文件系统块）。
 * opts.path 显式给路径时不看 now（生产用它挂时间戳），否则用 /tmp/dns-switch-diag-<stamp>.txt。
 */
export function collect(opts) {
	let now = now_of(opts);
	let text = render(opts);
	let path = opt_of(opts, 'path', '');
	if (!length(path)) path = sprintf('/tmp/dns-switch-diag-%s.txt', stamp(now, opts));

	if (fs.writefile(path, text) == null) {
		return { ok: false, code: 'E_INTERNAL', message: sprintf('写诊断包失败：%s', path), detail: {} };
	}
	return { ok: true, path: path, size: length(text) };
}
