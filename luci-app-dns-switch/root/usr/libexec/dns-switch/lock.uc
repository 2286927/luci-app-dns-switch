'use strict';

// ============================================================
// lock.uc —— L0 基础层：并发锁
//
// v1.0.1 用 `flock -n 9`。ucode **实测没有 flock 原语、也没有 exec**，
// 所以只能拿 mkdir(2) 的原子性当 test-and-set。锁就是一个目录：
//
//   <dir>/            目录本身 = 锁
//   <dir>/pid         持锁进程 pid（十进制 + \n）
//   <dir>/since       取锁时间（unix 秒 + \n）
//
// 加锁用「先搭后换」两步，全程没有"目录已在但 pid 文件还没写"的中间态：
//   1. 在 <dir>.new.<pid>.<ts> 建目录，写好 pid/since
//   2. rename 成 <dir>
//      —— 目标是非空目录时 rename 必然失败（实测 'Directory not empty'），
//         这就是"只有一个人能进去"的判据；目标若是空目录，rename 直接顶替，也对
//   3. rename 失败 → stat 看是不是被非目录占着（是就响亮报错，不静默顶替）
//      → holder() 看持锁者活没活：
//        活着  → 返回 reason='locked'（**不是**环境错误）
//        已死  → 把旧目录 rename 到 .stale.<pid>.<ts> 让位，再抢一次
//
// ------------------------------------------------------------
// 返回值（v2，见 SPEC §3.2 / IMPL-NOTES N22）
//
//   take(opts) → { ok:true, dir, pid }
//              | { ok:false, reason:'locked', holder:{pid,alive,since,age,stale} }
//              | { ok:false, reason:'env',    message }
//   drop(opts) → { ok:true }
//              | { ok:false, reason:'not-owner' }
//              | { ok:false, reason:'env', message }
//   holder(opts) → null | { pid, alive, since, age, stale }
//
// 为什么 take() 不再是 bool：**"锁被别人占"和"环境坏了"必须分开**。
// 两者都返回 false 时，调用方只能一律映射成 E_LOCKED（CLI rc=75）→
// 一旦盘满或只读，用户会永远看到"另一个实例在跑，稍后再试"，
// 而实际上永远不会成功 —— 静默死锁，且看起来像正常行为。
// 映射：locked → E_LOCKED(75)，env → E_INTERNAL(1)。
//
// ------------------------------------------------------------
// 所有 fs 错误语义（fs.error 读即清、禁止进控制流、mkdir/rename 的实测行为）
// 都在 fsutil.uc 的文件头——本文件只通过 err_msg() 拿文案拼消息，不拿它判断。
//
// 与 v1.0.1 的差异：锁路径按 SPEC §3.2 由 `/var/lock/dns-switch.lock`（flock 文件）
// 改为 `/var/lock/dns-switch.lock.d`（目录）。跨版本互斥**不靠锁本身**，靠
// postinst 第一步 stop 旧 daemon（SPEC §6.2 步 1）。
//
// 依赖：fs + ./fsutil.uc（不 import 任何上层模块）
// ============================================================

import { err_msg, ensure_dir, read_int, clear_dir } from './fsutil.uc';

let fs = require('fs');

const DIR_DEFAULT = '/var/lock/dns-switch.lock.d';
const NEW_SUFFIX = '.new.';
const STALE_SUFFIX = '.stale.';
const PROC = '/proc';

let held = null;    // { dir, pid }：本进程当前持有的锁
let mypid = null;

function env_fail(message) {
	return { ok: false, reason: 'env', message: message };
}

// ucode 没有 getpid()，只能读 /proc/self/stat 第一列
function self_pid() {
	if (mypid != null) return mypid;
	mypid = 0;
	let raw = fs.readfile(PROC + '/self/stat');
	if (type(raw) == 'string') {
		let m = match(raw, /^([0-9]+)/);
		if (m != null) mypid = +m[1];
	}
	return mypid;
}

function lockdir(opts) {
	if (opts != null && type(opts) == 'object') {
		let d = opts.dir;
		if (type(d) == 'string' && length(d)) return d;
	}
	if (held != null) return held.dir;
	return DIR_DEFAULT;
}

function alive(pid) {
	if (type(pid) != 'int' && type(pid) != 'double') return false;
	if (pid <= 0) return false;
	return fs.stat(PROC + '/' + pid) != null;
}

function write_stamp(dir, pid) {
	if (fs.writefile(dir + '/pid', sprintf('%d\n', pid)) == null) {
		return env_fail(sprintf('写 pid 文件失败：%s/pid（%s）', dir, err_msg()));
	}
	if (fs.writefile(dir + '/since', sprintf('%d\n', time())) == null) {
		return env_fail(sprintf('写 since 文件失败：%s/since（%s）', dir, err_msg()));
	}
	return { ok: true };
}

/**
 * 看当前谁持锁。没有锁 → null。
 * 返回 { pid, alive, since, age, stale }；pid 缺失时按 0 报。
 */
export function holder(opts) {
	let dir = lockdir(opts);
	let st = fs.stat(dir);
	if (st == null || st.type != 'directory') return null;

	let pid = read_int(dir + '/pid');
	let since = read_int(dir + '/since');
	if (since == null) since = st.mtime;
	let live = alive(pid);

	return {
		pid: (pid != null) ? pid : 0,
		alive: live,
		since: since,
		age: time() - since,
		stale: !live
	};
}

/**
 * 抢锁。返回 { ok:true } / { ok:false, reason:'locked' } / { ok:false, reason:'env' }。
 * **不抛异常**；reason='env' 说明是环境问题（目录建不出来、盘满、只读、被非目录占用），
 * 调用方应映射成 E_INTERNAL 而不是 E_LOCKED。
 */
export function take(opts) {
	let dir = lockdir(opts);

	// 同进程重入：daemon 里 do_on 内部又调 do_tick 这类路径不该自己卡自己
	if (held != null && held.dir == dir) return { ok: true, dir: dir, pid: held.pid };

	let pid = self_pid();
	if (pid <= 0) return env_fail('取不到自身 pid（读 /proc/self/stat 失败）');

	let pd = ensure_dir(fs.dirname(dir));
	if (!pd.ok) return env_fail(pd.message);

	let tmp = sprintf('%s%s%d.%d', dir, NEW_SUFFIX, pid, time());
	clear_dir(tmp);

	if (fs.mkdir(tmp) !== true) {
		return env_fail(sprintf('建临时锁目录失败：%s（%s）', tmp, err_msg()));
	}
	let ws = write_stamp(tmp, pid);
	if (!ws.ok) {
		clear_dir(tmp);
		return ws;
	}

	if (fs.rename(tmp, dir) === true) {
		held = { dir: dir, pid: pid };
		return { ok: true, dir: dir, pid: pid };
	}
	let why = err_msg();       // 只用来拼 message，不参与判断（读即清，见 fsutil.uc）

	// 锁路径上不该出现非目录的东西。有就响亮报错，**不静默顶替**——
	// 悄悄删掉别人的东西比报错更难查。
	let lst = fs.stat(dir);
	if (lst != null && lst.type != 'directory') {
		clear_dir(tmp);
		return env_fail(sprintf('锁路径被非目录占用：%s（%s），请人工清理', dir, why));
	}

	// 到这里只剩两种可能：活人持锁 / 陈旧残留（含"目录已消失"）
	let h = holder({ dir: dir });
	if (h != null && h.alive) {
		clear_dir(tmp);
		return { ok: false, reason: 'locked', holder: h };
	}

	// 陈旧锁接管：把旧目录挪走让位，再抢一次
	let grave = sprintf('%s%s%d.%d', dir, STALE_SUFFIX, pid, time());
	if (fs.rename(dir, grave) !== true) {
		clear_dir(tmp);
		return env_fail(sprintf('接管陈旧锁失败：%s（%s）', dir, err_msg()));
	}

	let won = (fs.rename(tmp, dir) === true);
	if (won) held = { dir: dir, pid: pid };
	else clear_dir(tmp);
	clear_dir(grave);

	if (won) return { ok: true, dir: dir, pid: pid };
	return env_fail(sprintf('接管陈旧锁后仍抢不到：%s', dir));
}

/**
 * 放锁。真放开 → { ok:true }；
 * 发现锁已不归自己（被别的进程当陈旧锁接管）→ { ok:false, reason:'not-owner' } 且
 * **不动**别人的目录；目录删不干净 → { ok:false, reason:'env' }。
 */
export function drop(opts) {
	let dir = lockdir(opts);
	let pid = self_pid();
	let mine = false;

	if (held != null && held.dir == dir) {
		mine = true;
		held = null;
	}

	if (!mine) {
		let owner = read_int(dir + '/pid');
		if (owner == null || pid <= 0 || owner != pid) {
			return { ok: false, reason: 'not-owner' };
		}
	}

	if (clear_dir(dir)) return { ok: true };
	return env_fail(sprintf('放锁时锁目录没删干净：%s', dir));
}
