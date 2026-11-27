'use strict';

// ============================================================
// switch-tier.uc —— L4：分级降级/回切的**纯判定**
//
// 四个函数全部只做判断、不执行：不写 uci、不 spawn、不落盘。
// 这样"连续失败两次该降级""冷却期内不降级""已 on 不重复 on"这些规则，
// 可以脱离 dnsmasq/nft 单独测——这是本模块存在的唯一理由。
//
// **不 import switch**（否则成环，G3 会红）。需要"执行 on"时用参数注入
// `{onFn}`：switch 传自己的 on 进来，tier 只负责"要不要调"。
//
// 阈值与 v1.0.1 对齐：连续失败 2 次降级、连续成功 2 次回切、冷却 120 s。
// ============================================================

const FAIL_N = 2;        // 连续探测失败多少次触发降级
const SUCC_N = 2;        // 连续成功多少次允许回切
const COOLDOWN = 120;    // 降级后冷却秒数（期内不再降级/回切）

function opt_of(opts, key, dflt) {
	if (opts != null && type(opts) == 'object') {
		let v = opts[key];
		if (type(v) == 'int') return v;
		if (type(v) == 'string' && length(v)) return v;
	}
	return dflt;
}

function setting(cfg, key) {
	if (cfg == null || type(cfg) != 'object' || cfg.ok != true) return '';
	let v = cfg.settings[key];
	return (type(v) == 'string') ? v : '';
}

/**
 * 配置 + 现场观察是否"看起来已经启用"（幂等判断用）。
 * `obs` 由调用方提供（本函数不读 nft/uci，保持纯）：
 *   { first_server, has_option6, frag_exists, chain_exists }
 * **契约写的是 state_looks_on(cfg)**；多出的 obs 是因为"链在不在"必须由外部观测，
 * 纯函数自己拿不到。已报架构师。
 */
export function state_looks_on(cfg, obs) {
	let adh = setting(cfg, 'adh_ip');
	if (!length(adh)) return false;
	if (obs == null || type(obs) != 'object') return false;
	if (obs.first_server != adh) return false;
	if (obs.has_option6 != true) return false;
	if (obs.frag_exists != true) return false;
	if (obs.chain_exists != true) return false;
	return true;
}

/**
 * 冷却期内？`state` = { now, cool_at }（cool_at 为 0 表示从未降级过）。
 * 缺 state 时按"不在冷却期"处理，让调用方走正常判定而不是永远拒绝。
 */
export function cooling(state, cfg) {
	if (state == null || type(state) != 'object') return false;
	let now = opt_of(state, 'now', 0);
	let at = opt_of(state, 'cool_at', 0);
	if (at <= 0 || now <= 0) return false;
	return (now - at) < COOLDOWN;
}

/**
 * 该不该降级。返回 { action:'failover'|'wait'|'skip', why }。
 *   skip  : 已经是 failover，或配置没启用（off 时不该降级）
 *   wait  : 连续失败不够 / 冷却期内
 *   failover: 真的该降级
 */
export function tier_failover(state, cfg) {
	let st = (state != null && type(state) == 'object') ? state : {};
	let eff = opt_of(st, 'effective', '');
	let streak = opt_of(st, 'fail_streak', 0);

	if (setting(cfg, 'mode') != 'on') return { action: 'skip', why: 'mode 不是 on' };
	if (eff == 'failover') return { action: 'skip', why: '已经处于降级' };
	if (cooling(st, cfg)) return { action: 'wait', why: '冷却期内' };
	if (streak < FAIL_N) {
		return { action: 'wait', why: sprintf('连续失败 %d < %d', streak, FAIL_N) };
	}
	return { action: 'failover', why: sprintf('连续失败 %d 次', streak) };
}

/**
 * 该不该回切。返回 { action:'full'|'reload'|'wait'|'skip', why, applied }。
 *   full  : 劫持链不在 → 必须走完整的 on（否则只有上游没有劫持）
 *   reload: 链在，只需重下发上游（<1s，比 on 便宜）
 *   wait  : 连续成功不够 / 冷却期内
 * 传了 opts.onFn 且 action=='full' 时才真的执行，`applied=true`。
 * **不传 onFn 就只回决策**——单测靠这个保持纯净。
 */
export function tier_on(state, cfg, opts) {
	let st = (state != null && type(state) == 'object') ? state : {};
	let eff = opt_of(st, 'effective', '');
	let streak = opt_of(st, 'ok_streak', 0);

	if (setting(cfg, 'mode') != 'on') return { action: 'skip', why: 'mode 不是 on', applied: false };
	if (eff == 'on') return { action: 'skip', why: '已经是 on', applied: false };
	if (cooling(st, cfg)) return { action: 'wait', why: '冷却期内', applied: false };
	if (streak < SUCC_N) {
		return { action: 'wait', why: sprintf('连续成功 %d < %d', streak, SUCC_N), applied: false };
	}

	let chain_ok = (opt_of(st, 'chain_exists', 0) == 1);
	if (!chain_ok) {
		let fn = (opts != null && type(opts) == 'object' && type(opts.onFn) == 'function')
			? opts.onFn : null;
		if (fn == null) return { action: 'full', why: '劫持链不在，需要完整 on', applied: false };
		fn();
		return { action: 'full', why: '劫持链不在，已执行完整 on', applied: true };
	}
	return { action: 'reload', why: '链在，只重下发上游', applied: false };
}
