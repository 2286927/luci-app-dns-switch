'use strict';

// ============================================================
// switch.uc —— L4：动作编排（on / off / apply_intent / init / drill）
//
// `on()` 的顺序照抄 P3-DESIGN §2.1-bis（九步 + 7b），**每一步反过来都是
// "返回值合法 + 现场不对"**，而单测碰不了现场、QEMU 只验通不通。所以顺序写在
// 函数头，改它之前先读一遍：
//   1 probe（两次机会；失败**一个字节都不改**就 return）
//   2 conflict.scan（block 则退出）
//   3 snapshot.save（**必须早于任何写**——回滚基准要在动土前拍）
//   4 nft.build（单调用点）→ check；失败去 MAC 重建再 check
//   5 dnsmasq.set_upstream + set_option6
//   6 state.commit('dhcp')；失败还原 dhcp
//   7 fw4 reload；失败 rollback
//   7b **等一拍**（reload 异步；早验会把"还没起来"判成失败 → 误写冷却 → 白等 120s）
//   8 dnsmasq.verify；失败 rollback
//   9 **再查劫持链是否存在**；不存在自动回滚（漏了它：全绿但没生效）
//
// 所有副作用都经 `opts.io`（注入**替身**，不是开关）：单测传 recorder/fake，
// 生产不传则用真实实现——这样"第 3/6/7b/9 步"在单测里仍然**被执行、被检查**。
//
// 依赖：config + state + probe + conflict + nft + dnsmasq + snapshot + log + sh
// ============================================================

import * as config from './config.uc';
import * as state from './state.uc';
import * as probe from './probe.uc';
import * as conflict from './conflict.uc';
import * as nft from './nft.uc';
import * as dnsmasq from './dnsmasq.uc';
import * as snapshot from './snapshot.uc';
import { log } from './log.uc';
import { run as sh_run } from './sh.uc';
import * as lock from './lock.uc';
import * as tickrun from './tick.uc';   // 别名避免与导出的 tick() 撞名

const FRAG = '/etc/nftables.d/20-dns-hijack.nft';
const SETTLE_MS = 1000;

// ---------- 工具（必须在使用者之前：ucode 不提升，N27）----------

function opt_of(opts, key, dflt) {
	if (opts != null && type(opts) == 'object') {
		let v = opts[key];
		if (type(v) == 'string' && length(v)) return v;
		if (type(v) == 'int') return v;
		if (type(v) == 'bool') return v;
		if (type(v) == 'array') return v;
		if (type(v) == 'object') return v;
	}
	return dflt;
}

function f(opts, key, dflt) {
	let io = opt_of(opts, 'io', null);
	if (io != null && type(io[key]) == 'function') return io[key];
	return dflt;
}

// 默认落点：真调各领域模块。单测通过 opts.io 换成替身。
function io_default(opts) {
	return {
		probe: f(opts, 'probe', function () { return probe.probe(); }),
		scan: f(opts, 'scan', function () { return conflict.scan({ wait: false }); }),
		snapshot_save: f(opts, 'snapshot_save', function () { return snapshot.save(); }),
		check: f(opts, 'check', function (p) { return nft.check(p); }),
		write: f(opts, 'write', function (dot, mac, adh) { return nft.write(FRAG, dot, mac, adh); }),
		present: f(opts, 'present', function () { return nft.present(); }),
		set_upstream: f(opts, 'set_upstream', function (l) { return dnsmasq.set_upstream(l); }),
		set_option6: f(opts, 'set_option6', function (l) { return dnsmasq.set_option6(l); }),
		commit: f(opts, 'commit', function (c) { return state.commit(c); }),
		reload: f(opts, 'reload', function () { return sh_run('/sbin/fw4 reload'); }),
		wait: f(opts, 'wait', function (ms) { return sh_run(sprintf('sleep %d', ms / 1000)); }),
		verify: f(opts, 'verify', function (d) { return dnsmasq.verify(d); }),
		restore: f(opts, 'restore', function (id) { return snapshot.restore(id); })
	};
}

// 第 4 步：**单调用点**——adh 只在这里出现一次，重试路径不可能漏传
function make_frag(cfg, mac) {
	return nft.build(cfg.settings.dot853, mac, cfg.settings.adh_ip);
}

function fail(code, message) {
	log(message);
	return { ok: false, code: code, message: message, detail: {} };
}

function rollback(io, id) {
	if (type(id) != 'string' || !length(id)) return false;
	let r = io.restore(id);
	return (r != null && r.ok == true);
}

// ---------- 导出 ----------

/**
 * 开启。步骤顺序见文件头，**不要重排**。
 * opts.io 是注入替身（生产不传）；opts.wait_ms 默认 1000。
 */
export function on(opts) {
	let io = io_default(opts);
	let cfg = config.load(opts);
	if (cfg == null || cfg.ok != true) {
		return fail('E_INTERNAL', '配置读不到，未做任何改动');
	}
	let adh = cfg.settings.adh_ip;
	let port = cfg.settings.adh_port;
	let dom = cfg.settings.probe_domain;
	let mac = cfg.settings.adh_mac;

	// 1 探活：两次机会。失败**不改任何东西**
	let p1 = io.probe();
	if (p1 == null || p1.ok != true) p1 = io.probe();
	if (p1 == null || p1.ok != true) {
		return fail('E_PRECOND_GATE', 'AdGuardHome 探活失败，未做任何改动');
	}

	// 2 冲突闸门
	let sc = io.scan();
	if (sc != null && sc.level == 'block') {
		return fail('E_PRECOND_GATE', sprintf('53 端口冲突（%s），拒绝切换', sc.by));
	}

	// 3 快照：必须早于任何写
	let snap = io.snapshot_save();
	let snap_id = (snap != null && type(snap.id) == 'string') ? snap.id : '';

	// 4 片段：单调用点 + 失败去 MAC 重建
	let okf = io.check(make_frag(cfg, mac));
	if (okf == null || okf.ok != true) {
		okf = io.check(make_frag(cfg, ''));
		mac = '';
		if (okf == null || okf.ok != true) {
			return fail('E_NFT_INVALID', 'nft 片段预检失败（含去 MAC 重建）');
		}
	}

	// 5+6 下发 uci 并提交 dhcp
	let up = io.set_upstream([ adh ]);
	if (up == null || up.ok != true) return fail('E_UCI_COMMIT', '写上游失败');
	let o6 = io.set_option6([ adh ]);
	if (o6 == null || o6.ok != true) return fail('E_UCI_COMMIT', '写 option6 失败');
	let cm = io.commit('dhcp');
	if (cm == null || cm.ok != true) {
		return fail('E_UCI_COMMIT', 'commit dhcp 失败（dhcp 段未生效）');
	}

	// 7 落盘 + reload
	let w = io.write(cfg.settings.dot853, mac, adh);
	if (w == null || w.ok != true) {
		return fail('E_INTERNAL', '写 nft 片段失败');
	}
	let rl = io.reload();
	if (rl != null && rl.rc != null && rl.rc != 0) {
		rollback(io, snap_id);
		return fail('E_INTERNAL', 'fw4 reload 失败，已回滚');
	}

	// 7b 等一拍：reload 异步，早验会把"还没起来"判成失败
	let ms = opt_of(opts, 'wait_ms', SETTLE_MS);
	io.wait(ms);

	// 8 自检
	let v = io.verify(dom);
	if (v == null || v.ok != true) {
		rollback(io, snap_id);
		return fail('E_APPLY_FAILED', '切换后解析失败，已回滚');
	}

	// 9 再查产物：reload 成功不代表规则进了内核
	let pr = io.present();
	if (pr == null || pr.hijack != true) {
		rollback(io, snap_id);
		return fail('E_NFT_INVALID', '劫持链未生效，已回滚');
	}

	state.set_status('effective', 'on');
	state.set_status('last_change', "" + time());
	state.commit();
	log('已切换到 AdGuardHome');
	return { ok: true, snapshot: snap_id, mac: mac };
}

/**
 * 周期入口：**取锁 → 转调 tick.run → 放锁**。
 *
 * 锁是 switch 的职责（v1.0.1 `tick) lock_take || exit 0; do_tick ;;`）。
 * 三个不许：① 不许做成纯转发（tick.run 自己不加锁 = 没有互斥）；
 * ② 不许让 main 直接调 tick.run；③ 不许在 tick.run 内部再加锁（会自锁死）。
 * 为什么必须互斥：两个 tick 并发会同时读写 C9 五个运行态文件，
 * 典型后果是"两次都读到 fail=1，各写 2，实际该到 3"——降级/回切时机漂移，
 * 且只在重叠时出现（procd 55s + 手工 tick + apply-intent 三条路径都可能撞）。
 */
export function tick(opts) {
	let lo = (opts != null && type(opts) == 'object' && type(opts.lock_dir) == 'string'
		&& length(opts.lock_dir)) ? { dir: opts.lock_dir } : null;

	let lk = (lo != null) ? lock.take(lo) : lock.take();
	if (lk == null || lk.ok != true) {
		// 与 v1.0.1 的 `lock_take || exit 0` 同义：静默跳过，不是失败
		return { ok: true, action: 'skipped', why: 'locked' };
	}

	let r = null;
	try {
		r = tickrun.run(opts);
	} catch (e) {
		r = { ok: false, code: 'E_INTERNAL', message: sprintf('tick 异常：%s', e) };
	}
	// 必须放锁：省了就是永久占锁（下次 tick 永远 skipped）
	if (lo != null) lock.drop(lo); else lock.drop();
	return r;
}

/** 关闭：**空壳**（P3 后续实现）。返回明确错误码，不是 TODO 注释——
 *  它会被调用方当成失败，而注释不会。 */
export function off(opts) {
	return { ok: false, code: 'E_INTERNAL', message: 'not implemented (P3 后续)' };
}

/** 按 settings.mode 落意图：**空壳**。 */
export function apply_intent(opts) {
	return { ok: false, code: 'E_INTERNAL', message: 'not implemented (P3 后续)' };
}

/** 开机初始化：**空壳**。 */
export function init(opts) {
	return { ok: false, code: 'E_INTERNAL', message: 'not implemented (P3 后续)' };
}

/** 演练：**空壳**。 */
export function drill(opts) {
	return { ok: false, code: 'E_INTERNAL', message: 'not implemented (P3 后续)' };
}
