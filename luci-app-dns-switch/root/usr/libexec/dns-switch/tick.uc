'use strict';

// ============================================================
// tick.uc —— L4：55 s 周期与降级执行（**不纯半边**）
//
// 分工死线：**本文件不做任何业务判定**。判定全在 `switch-tier`
// （阈值 2/3/120 都在那边），这里只做"读运行态 → 问 tier → 执行 → 写运行态"。
// 需要新判定（如"计数该不该重置"）时加进 switch-tier，不加这里。
//
// C9 五个运行态文件（路径全部走 opts.state_dir，单测不许写真 /tmp）：
//   fail / succ / cooldown / last_check / probe-fail
// ============================================================

import * as config from './config.uc';
import * as state from './state.uc';
import * as tier from './switch-tier.uc';
import * as dnsmasq from './dnsmasq.uc';
import * as nft from './nft.uc';
import { log } from './log.uc';

let fs = require('fs');

const STATE_DIR = '/tmp';
const NAMES = {
	fail: 'dns-switch.fail', succ: 'dns-switch.succ', cooldown: 'dns-switch.cooldown',
	last_check: 'dns-switch.last_check', probe_fail: 'dns-switch.probe-fail'
};

function opt_of(opts, key, dflt) {
	if (opts != null && type(opts) == 'object') {
		let v = opts[key];
		if (type(v) == 'string' && length(v)) return v;
		if (type(v) == 'int') return v;
		if (type(v) == 'bool') return v;
	}
	return dflt;
}

function dir_of(opts) {
	let d = opt_of(opts, 'state_dir', STATE_DIR);
	if (!length(d)) d = STATE_DIR;
	return d;
}

function path_of(opts, name) {
	return dir_of(opts) + '/' + NAMES[name];
}

function read_int(opts, name) {
	let t = fs.readfile(path_of(opts, name));
	if (type(t) != 'string') return 0;
	let v = trim(t);
	if (match(v, /^-?[0-9]+$/) == null) return 0;
	return +v;
}

function write_int(opts, name, v) {
	let n = fs.writefile(path_of(opts, name), sprintf('%d\n', v));
	return n != null;
}

/** 读运行态 → 交给 switch-tier 判定所需的 state。不判定、只搬运。 */
export function read_state(opts) {
	let eff = state.get_opt('dns_switch', 'status', 'effective');
	let chain = opt_of(opts, 'chain_exists', null);
	if (chain == null) chain = nft.present().hijack;

	return {
		now: opt_of(opts, 'now', time()),
		cool_at: read_int(opts, 'cooldown'),
		effective: (eff != null) ? eff : '',
		fail_streak: read_int(opts, 'fail'),
		ok_streak: read_int(opts, 'succ'),
		chain_exists: (chain == true) ? 1 : 0
	};
}

/**
 * 一轮的**决策**：读文件 → 问 tier → 回 {action, why}。**不执行任何系统动作**。
 * action ∈ failover | reload | full | none。
 * 配置读不到时回 {ok:false}，不猜。
 */
export function tick_once(opts) {
	let st = read_state(opts);
	let cfg = config.load(opts);
	if (cfg == null || cfg.ok != true) {
		return {
			ok: false,
			code: (cfg != null && cfg.code != null) ? cfg.code : 'E_INTERNAL',
			message: (cfg != null && cfg.message != null) ? cfg.message : '配置读不到',
			action: 'none',
			why: ''
		};
	}

	// 降级优先于回切（同 v1.0.1 的顺序）
	let down = tier.tier_failover(st, cfg);
	if (down.action == 'failover') {
		return { ok: true, action: 'failover', why: down.why };
	}

	let up = tier.tier_on(st, cfg);
	if (up.action == 'reload' || up.action == 'full') {
		return { ok: true, action: up.action, why: up.why };
	}

	return { ok: true, action: 'none', why: (down.why + ' / ' + up.why) };
}

/**
 * 执行一轮：决策（tick_once）+ 落地动作 + 写运行态。
 * opts.apply == false 时**只决策不执行**（单测用，绝不碰 dnsmasq/nft）。
 */
export function run(opts) {
	let o = (opts != null && type(opts) == 'object') ? opts : {};
	let d = tick_once(o);

	write_int(o, 'last_check', opt_of(o, 'now', time()));

	if (d.ok != true) return d;
	if (d.action == 'none' || opt_of(o, 'apply', true) == false) return d;

	let cfg = config.load(o);
	if (cfg == null || cfg.ok != true) return d;

	if (d.action == 'failover') {
		let list = opt_of(o, 'isp_list', null);
		if (type(list) != 'array') return { ok: false, code: 'E_INTERNAL', message: '降级需要上游列表', action: d.action };
		let r = dnsmasq.set_upstream(list);
		if (!r.ok) return { ok: false, code: r.code, message: r.message, action: d.action };
		// 冷却起点：只有真的切成功才写（写早了会把重试窗口锁死）
		write_int(o, 'cooldown', opt_of(o, 'now', time()));
		write_int(o, 'fail', 0);
		log('ADH 不可用，已降级到运营商 DNS');
		return { ok: true, action: 'failover', why: d.why };
	}

	// reload / full：重新下发上游（回切路径）
	let want = opt_of(o, 'adh_upstream', null);
	if (type(want) != 'array') return { ok: false, code: 'E_INTERNAL', message: '回切需要 ADH 上游', action: d.action };
	let r2 = dnsmasq.set_upstream(want);
	if (!r2.ok) return { ok: false, code: r2.code, message: r2.message, action: d.action };

	write_int(o, 'cooldown', opt_of(o, 'now', time()));
	write_int(o, 'succ', 0);
	log('ADH 已恢复，回切到 ADH 上游');
	return { ok: true, action: 'reload', why: d.why };
}
