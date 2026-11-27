'use strict';

// ============================================================
// status.uc —— L3：组装 status 对象（**唯一**允许拼它的地方）
//
// 四条硬约束（SPEC §4.1 / §4.3 / N24）：
//   1. **不许调 `conflict.scan()`**：前端 5 s 一 poll，scan 要翻 6k inode，
//      P95 ≤300 ms 直接穿。只读 `conflict.cache_read()`（拿不到返回 null）。
//   2. **不许 spawn 任何子进程**：本文件不 import sh，也不调 probe() 的探测路径
//      （`probe.reason()` 是纯函数，可以用）。测试里有一条结构断言直接扫源码，
//      出现 `run(`/`runq(` 就红。
//   3. **`cfg.ok=false` 必须把 ok/code/message 带上去**（N24）：否则前端看到
//      "ADH 状态未知"，而真相是"配置读不到"——两者对用户是不同的事。
//   4. **不格式化时间**：`last_change` 一律输出 epoch 整数。ucode 没有 strftime，
//      格式化只能 popen `date`，那与约束 2 冲突；格式化交给 CLI/前端。
//
// 依赖：config + conflict + nft + dnsmasq + probe + fs（**没有 sh**）
// ============================================================

import * as config from './config.uc';
import * as conflict from './conflict.uc';
import * as nft from './nft.uc';
import * as dnsmasq from './dnsmasq.uc';
import * as probe from './probe.uc';

let fs = require('fs');

const EMPTY_CONFLICT = { level: 'unknown', by: '', why: '', fix: '' };
const EMPTY_NFT = { hijack: false, ether: 0, dot_block: false };
const EMPTY_PTR = { first: '', port: 0 };

function opt_of(opts, key, dflt) {
	if (opts != null && type(opts) == 'object') {
		let v = opts[key];
		if (type(v) == 'string' && length(v)) return v;
	}
	return dflt;
}

// 骨架子段：即使配置读不到也要有形状（方案 B / N24）
function empty_frames() {
	return {
		mode: '', effective: '', probe: '', reason: '', dep: '', adh_mac: '',
		upstream: [], last_change: 0, error: '',
		conflict: { level: EMPTY_CONFLICT.level, by: '', why: '', fix: '' },
		nft: { hijack: false, ether: 0, dot_block: false },
		dnsmasq: { first: '', port: 0 }
	};
}

function split_upstream(s) {
	let out = [];
	if (type(s) != 'string' || !length(s)) return out;
	let raw = split(trim(s), ' ');
	for (let i = 0; i < length(raw); i++) if (length(raw[i])) push(out, raw[i]);
	return out;
}

function int_of(v) {
	if (type(v) == 'int') return v;
	if (type(v) == 'string' && match(trim(v), /^-?[0-9]+$/) != null) return +trim(v);
	return 0;
}

/** 版本号：优先读包版本文件（只读一次、不 spawn）。读不到返回空串。 */
function version_of(opts) {
	let p = opt_of(opts, 'version_path', '/usr/share/dns-switch/version');
	let t = fs.readfile(p);
	if (type(t) != 'string') return '';
	return trim(t);
}

/**
 * 组装 status。**纯读 + 拼**，不 spawn、不写、不扫端口。
 * opts 是统一的测试缝（confdir 给 config/state；repeat 之类不在这里用）。
 */
export function collect(opts) {
	let out = empty_frames();

	let cfg = config.load(opts);
	if (cfg == null || cfg.ok != true) {
		out.ok = false;
		out.code = (cfg != null && cfg.code != null) ? cfg.code : 'E_INTERNAL';
		out.message = (cfg != null && cfg.message != null) ? cfg.message : '配置读不到';
		out.version = version_of(opts);
		return out;
	}

	let s = cfg.settings;
	let st = cfg.status;

	out.mode = s.mode;
	out.effective = st.effective;
	out.probe = st.probe;
	out.reason = st.reason;
	out.dep = st.dep;
	out.adh_mac = length(st.adh_mac) ? st.adh_mac : s.adh_mac;
	out.upstream = split_upstream(st.upstream);
	out.last_change = int_of(st.last_change);
	out.error = st.error;
	out.version = version_of(opts);

	// 冲突：**只读缓存**，不扫。缓存缺失/过期 → unknown + 说明，不报错
	let cache = conflict.cache_read(opts);
	if (cache == null) {
		out.conflict = { level: 'unknown', by: '', why: '还没扫过（由 tick 每 55 s 刷新）', fix: '' };
	}
	else {
		out.conflict = {
			level: cache.level, by: cache.by, why: cache.why, fix: cache.fix
		};
	}

	// nft 与 dnsmasq 都是只读探测（present/pointers 内部只跑 nft 只读命令与 uci 读）
	let pr = nft.present();
	out.nft = {
		hijack: (pr.hijack == true),
		ether: (type(pr.ether) == 'int') ? pr.ether : 0,
		dot_block: (pr.dot_block == true)
	};
	let pt = dnsmasq.pointers();
	out.dnsmasq = { first: pt.first, port: pt.port };

	out.ok = true;
	out.code = 'OK';
	out.message = '';
	return out;
}

/**
 * 渲染成人话（C4 的文本半边）。**纯函数**：只吃 collect() 的结果，不再探测。
 * 时间不在这里格式化（约束 4）：直接印 epoch，CLI 层想美化自己处理。
 */
export function render_text(obj) {
	if (obj == null || type(obj) != 'object') return '';
	let L = [];
	if (obj.ok != true) {
		push(L, sprintf('配置读不到：%s（%s）', obj.message, obj.code));
		return join('\n', L) + '\n';
	}
	push(L, sprintf('模式       %s', obj.mode));
	push(L, sprintf('实际状态   %s', obj.effective));
	push(L, sprintf('探活       %s', obj.probe));
	push(L, sprintf('原因       %s', obj.reason));
	push(L, sprintf('上游首项   %s', length(obj.dnsmasq.first) ? obj.dnsmasq.first : '空'));
	push(L, sprintf('监听端口   %d', obj.dnsmasq.port));
	push(L, sprintf('劫持链     %s（ether 豁免 %d）',
		obj.nft.hijack ? '在位' : '缺失', obj.nft.ether));
	push(L, sprintf('53 冲突    %s%s', obj.conflict.level,
		length(obj.conflict.by) ? (' ' + obj.conflict.by) : ''));
	if (length(obj.conflict.why)) push(L, sprintf('           %s', obj.conflict.why));
	if (length(obj.error)) push(L, sprintf('错误       %s', obj.error));
	push(L, sprintf('最后变更   %d', obj.last_change));
	return join('\n', L) + '\n';
}
