'use strict';

// ============================================================
// switch-tier.uc —— L4：分级降级/回切的**纯判定**
//
// 四个函数全部只做判断、不执行：不写 uci、不 spawn、不落盘。
// 这样"连续失败两次该降级""冷却期内不降级""已 on 不重复 on"这些规则，
// 可以脱离 dnsmasq/nft 单独测——这是本模块存在的唯一理由。
//
// **不 import switch**（否则成环，G3 会红），也**不从外面注入回调**：
// 回切后重新下发走 dnsmasq/nft，不调 switch.on（U30），所以这里只回决策。
// 零 import 这件事由 A6（内建依赖）+ G3（依赖图孤立点）两条门禁守着，
// 谁想加 require('fs') 都会当场红——这是"纯"能被机器验证的唯一形式。
//
// 阈值**逐值对齐 v1.0.1 dns-switch:48-50**：FAIL_NEED=2 / SUCC_NEED=3 / COOLDOWN=120。
// 比较语义是 `>=`（原文用 `-ge`）。漂一个值不会报错，只会在真机上表现为早/晚一次探测。
// ============================================================

const FAIL_N = 2;        // 连续失败几次才降级（v1.0.1:49 FAIL_NEED=2）
const SUCC_N = 3;        // 连续成功多少次允许回切（v1.0.1 dns-switch:50 SUCC_NEED=3）
const COOLDOWN = 120;    // 两次迁移之间的冷却秒数（v1.0.1:48）

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
	if (eff != 'on') return { action: 'skip', why: sprintf("effective=%s，不是 on（v1.0.1:1662 同口径）", length(eff) ? eff : '空') };
	if (cooling(st, cfg)) return { action: 'wait', why: '冷却期内' };
	if (streak < FAIL_N) {
		return { action: 'wait', why: sprintf('连续失败 %d < %d', streak, FAIL_N) };
	}
	return { action: 'failover', why: sprintf('连续失败 %d 次', streak) };
}

/**
 * 该不该回切。返回 { action:'full'|'reload'|'wait'|'skip', why }。
 *   full  : 劫持链不在 → 必须走完整的 on（否则只有上游没有劫持）
 *   reload: 链在，只需重下发上游（<1s，比 on 便宜）
 *   wait  : 连续成功不够 / 冷却期内
 * **只回决策、不执行**：回切后重下发走 dnsmasq/nft，不调 switch.on，
 * 所以既不需要 onFn 也不需要 applied（U30：没人用的参数就是过度设计）。
 */
export function tier_on(state, cfg) {
	let st = (state != null && type(state) == 'object') ? state : {};
	let eff = opt_of(st, 'effective', '');
	let streak = opt_of(st, 'ok_streak', 0);

	if (setting(cfg, 'mode') != 'on') return { action: 'skip', why: 'mode 不是 on' };
	if (eff == 'on') return { action: 'skip', why: '已经是 on' };
	if (cooling(st, cfg)) return { action: 'wait', why: '冷却期内' };
	if (streak < SUCC_N) {
		return { action: 'wait', why: sprintf('连续成功 %d < %d', streak, SUCC_N) };
	}

	let chain_ok = (opt_of(st, 'chain_exists', 0) == 1);
	if (!chain_ok) return { action: 'full', why: '劫持链不在，需要完整 on' };
	return { action: 'reload', why: '链在，只重下发上游' };
}
