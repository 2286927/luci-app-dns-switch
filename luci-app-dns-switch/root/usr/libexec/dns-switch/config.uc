'use strict';

// ============================================================
// config.uc —— L1 配置层：uci 的**唯一对外出口**
//
// 承接 v1.0.1 的 s_opt / t_opt / reload_cfg / need_cfg / ensure_config /
// st_set / st_commit / sig_now。
//
// 分工（P3-DESIGN §1.2 / IMPL-NOTES N23 拆分后）：
//   state.uc  = 怎么和 uci 说话（cursor、建/修配置、读写、commit）
//   config.uc = 说什么（§3.4 缺省值 resolve、对外视图、签名）
//
// **写路径没有别名**：config 只导出 load() / opt() / sig()。
// 写 status 一律 `state.set_status(k,v)` + `state.commit()`——
// 曾经在 config 里留过 state_set()/commit() 两个薄壳，被 team-lead 判为
// "两套写法并存，下次改动只会改一处"，已删。别再补回来。
//
// 由此带来一条使用约束：**写完想立刻读，必须重新 load()**。
// 原因：cfg 是 load() 那一刻的快照，而 state 写的是 uci；
// 不重新 load() 就读 cfg.status.x 会拿到旧值（v1.0.1 每次 uci get 都是新读，
// 所以这是拆分新引入的唯一语义差异，写在这里防止后来人踩）。
//
// 铁律（SPEC §3.4）：
//   1. 缺省值**只在这里** resolve 一次；其它模块不许再写 `?? default`。
//      opt(k, def) 的 def 只留给表外的键——表内键在 load() 已经填好。
//   2. 配置文件不存在 / status 段缺失的**修复动作**在 state.open() 里，
//      这里只负责把结果读成对象；任何一步失败都返回 ok:false。
//   3. uci commit 失败 → code=E_UCI_COMMIT，**禁止**静默继续。
//
// 返回值形状：load() 直接返回已解析对象，对象里额外带 ok / code / message
// 做错误通道（配置键里没有同名的，不会撞）。
//
// 数字一律保持 uci 里的**字符串**（"3030" 不是 3030）：
//   sig() 要与 v1.0.1 的 sig_now 逐字节比对，JSON 侧的数值转换是 status/rpcd 的活。
//
// opts（仅供单测）：load({confdir:"/tmp/x"}) 把 uci 根指到临时目录，
//   生产调用一律 load() / state_set() / commit() / sig() 不带参数。
//
// 依赖：./state.uc（不 import 任何上层模块）
// ============================================================

import * as state from './state.uc';

const SECT = 'settings';
const STAT = 'status';

// ---- §3.4 缺省值表：全项目唯一的 resolve 点 ----
const DEFAULTS = {
	mode: 'off',
	dot853: 'allow',
	upstream_mode: 'auto',
	adh_ip: '172.16.1.2',
	adh_port: '3030',
	fallback_dns: '172.16.5.5',
	fallback_dns6: '',
	adh_mac: '',
	probe_domain: 'www.baidu.com',
	isp_list4: '',
	isp_list6: '',
	isp_list: '',        // v1.0.x 遗留单行字段，isp_dns 的 manual 分支还在读
	auto_failover: '1',
	probe_now: '0',
	request_at: '0'
};

// status 段不给"发明出来的缺省值"：v1.0.1 里这些字段空就是空，
// 补默认会改变 status 页面显示（I1）。null → '' 只是归一化。
const STATUS_KEYS = [
	'effective', 'probe', 'reason', 'dep', 'adh_mac', 'upstream',
	'last_change', 'error', 'conflict', 'conflict_by', 'conflict_msg',
	'conflict_fix', 'applied_sig'
];

let cfg = null;      // 最近一次 load() 的已解析对象

function resolve(k) {
	let v = state.get(SECT, k);
	if (v == null || !length(v)) return DEFAULTS[k];   // 对应 shell 的 ${X:-default}
	return v;
}

/**
 * 方案 B（SPEC §3.4 / DECISIONS U13）：失败也返回**完整骨架**。
 *
 * 为什么：原来失败只返回 {ok,code,message,detail}，没有 settings/status；
 * 调用方漏判 ok 时 `cfg.status.effective` 就是**对 null 取字段 → 进程崩溃**，
 * rc=254。254 不在 §4.2 的 0/1/2/3/4/75 里，脚本侧完全看不懂。
 *
 * 骨架值用**空哨兵**不用 null（N2：type(null) 返回 null 本身，判不出来）：
 *   字符串 ''、数值 0。last_change 是唯一的数值字段，给 0。
 *
 * 代价（N24 纪律）：骨架只解决"不崩"，不解决"可信"。settings/status 恒存在
 * ⇒ `if (cfg.status)` 这类存在性判断**恒真**，等于没有判断。
 * 所有消费方必须先查 cfg.ok，再映射 §4.2 的 E_*。
 */
function skeleton(code, message, detail) {
	let out = { ok: false, code: code, message: message, detail: detail };
	let s = {};
	let t = {};
	let k;

	for (k in DEFAULTS) s[k] = '';
	for (let i = 0; i < length(STATUS_KEYS); i++) t[STATUS_KEYS[i]] = '';
	t.last_change = 0;          // 唯一数值字段，按契约给 0 而不是 ''

	out.settings = s;
	out.status = t;
	return out;
}

/**
 * 读 + resolve，返回已解析配置对象：
 *   { ok:true,  code:'OK', message:'', detail:{}, settings:{…}, status:{…} }
 *   { ok:false, code:'E_*', message, detail,    settings:{…空哨兵}, status:{…空哨兵} }
 * **ok=false 时字段值不可信**，只代表"形状完整、不会崩"。
 */
export function load(opts) {
	let opened = state.open(opts);
	if (!opened.ok) {
		cfg = skeleton(opened.code, opened.message,
			(type(opened.detail) == 'object' && opened.detail != null) ? opened.detail : {});
		return cfg;
	}

	let settings = {};
	let k;
	for (k in DEFAULTS) settings[k] = resolve(k);

	let status = {};
	for (let i = 0; i < length(STATUS_KEYS); i++) {
		let key = STATUS_KEYS[i];
		let v = state.get(STAT, key);
		status[key] = (v != null) ? v : '';
	}

	cfg = { ok: true, code: 'OK', message: '', detail: {} };
	cfg.settings = settings;
	cfg.status = status;
	return cfg;
}

/**
 * 取一个配置键（读 settings 段）。§3.4 表内的键在 load() 已 resolve，
 * def 只对表外的键有意义。
 * 判空用 `=== null`：实测 ucode 的 type(null) 返回 null 本身，不是 "null"。
 * 注意：ok=false 时拿到的是空哨兵，**看起来像"值为空"而不是"读不到"**，
 *       所以消费方必须先查 cfg.ok（N24），别靠这里的返回值判断配置是否可读。
 */
export function opt(k, def) {
	if (cfg == null) return def;
	let v = cfg.settings[k];
	if (v === null) return def;
	return v;
}

/**
 * 关键参数签名，必须与 v1.0.1 sig_now() 逐字节一致：
 *   "$ADH|$ADH_PORT|$FB|$FB6|$DOT853|$MAC_CFG|$UPSTREAM_MODE|isp_list4|isp_list6"
 * 调用前先 load()；load 没成功时返回空串（与"取不到值"同义）。
 */
export function sig() {
	if (cfg == null || cfg.ok != true) return '';
	let s = cfg.settings;
	return sprintf('%s|%s|%s|%s|%s|%s|%s|%s|%s',
		s.adh_ip, s.adh_port, s.fallback_dns, s.fallback_dns6,
		s.dot853, s.adh_mac, s.upstream_mode, s.isp_list4, s.isp_list6);
}
