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
// 加锁用「先搭后换」两步，全程没有「目录已在但 pid 文件还没写」的中间态：
//   1. 在 <dir>.new.<pid>.<ts> 建目录，写好 pid/since
//   2. rename 成 <dir>
//      —— 目标是非空目录时 rename 必然失败（实测 "Directory not empty"），
//         这就是"只有一个人能进去"的判据；目标若是空目录，rename 直接顶替，也对
//   3. rename 失败 → 看持锁者活没活：
//        活着        → 返回 reason='locked'（**不是**环境错误）
//        已死        → 把旧目录 rename 到 .stale.<pid>.<ts> 让位，再抢一次
//
// ------------------------------------------------------------
// 返回值（v2，见 DECISIONS/IMPL-NOTES N21）
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
// 一旦 /var 满或只读，用户会永远看到"另一个实例在跑，稍后再试"，
// 而实际上永远不会成功 —— 静默死锁，且看起来像正常行为。
//
// ------------------------------------------------------------
// fs.error() 的两条实测铁律（踩过就记牢）
//   1. **只在调用返回 null/false 之后读，且必须紧跟下一句**。
//      中间插任何 fs 调用（哪怕只是 fs.stat）都会被清成 null，
//      于是"失败"被读成"没有错误" → 误判成功。
//   2. **成功之后不要读**：mkdir 成功会清成 null，但 rename 成功可能留下
//      上一次的旧文案。所以本文件只在失败分支取 error。
//
// 另：fs.mkdir 对「已存在」和「父目录缺失」都返回 null（实测），
// 靠 error 文案区分（"File exists" / "No such file or directory"）；
// fs.rmdir / fs.unlink 对不存在的路径返回 null 且**不抛异常**。
//
// 与 v1.0.1 的差异：锁路径按 SPEC §3.2 由 `/var/lock/dns-switch.lock`（flock 文件）
// 改为 `/var/lock/dns-switch.lock.d`（目录）。跨版本互斥**不靠锁本身**，靠
// postinst 第一步 stop 旧 daemon（SPEC §6.2 步 1）。
//
// 依赖：fs（不 import 任何 ./x.uc）
// ============================================================

let fs = require('fs');

const DIR_DEFAULT = '/var/lock/dns-switch.lock.d';
const NEW_SUFFIX = '.new.';
const STALE_SUFFIX = '.stale.';
const PROC = '/proc';

// rename 撞上"目标非空目录"时的文案；"File exists" 兜一层（不同内核/实现对
// rename 到非空目录可能报 EEXIST 而不是 ENOTEMPTY）
const E_NOTEMPTY = 'Directory not empty';
const E_EXIST = 'File exists';

let held = null;    // { dir, pid }：本进程当前持有的锁
let mypid = null;

function env_fail(message) {
	return { ok: false, reason: 'env', message: message };
}

// 只在失败的 fs 调用**紧跟**着用（见文件头铁律 1）
function err_text() {
	let e = fs.error();
	if (type(e) == 'string' && length(e)) return e;
	return 'unknown';
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

// mkdir -p（fs.mkdir 不建父目录，实测），失败要把**原因**带出来
function ensure_dir(path) {
	if (type(path) != 'string' || !length(path) || path == '/') return { ok: true };

	let st = fs.stat(path);
	if (st != null && st.type == 'directory') return { ok: true };

	let parent = fs.dirname(path);
	if (parent == path) return env_fail(sprintf('无法创建目录：%s', path));

	let pd = ensure_dir(parent);
	if (!pd.ok) return pd;

	let r = fs.mkdir(path);
	if (r === true) return { ok: true };
	let err = err_text();                 // 必须紧跟 mkdir
	let st2 = fs.stat(path);              // 取完 error 再 stat
	if (st2 != null && st2.type == 'directory') return { ok: true };   // EEXIST 且确实是目录
	return env_fail(sprintf('创建目录失败：%s（%s）', path, err));
}

function alive(pid) {
	if (type(pid) != 'int' && type(pid) != 'double') return false;
	if (pid <= 0) return false;
	return fs.stat(PROC + '/' + pid) != null;
}

function read_int(path) {
	let raw = fs.readfile(path);
	if (type(raw) != 'string') return null;
	let m = match(trim(raw), /^-?[0-9]+$/);
	if (m == null) return null;
	return +trim(raw);
}

// 清目录（不跟随软链，最多两级，够用且不会误伤）
function clear_dir(dir) {
	let st = fs.stat(dir);
	if (st == null) return true;
	if (st.type != 'directory') return fs.unlink(dir) != null;

	let names = fs.lsdir(dir);
	if (type(names) == 'array') {
		for (let i = 0; i < length(names); i++) {
			let name = names[i];
			if (name == '.' || name == '..') continue;
			let child = dir + '/' + name;
			let cst = fs.stat(child);
			if (cst != null && cst.type == 'directory') clear_dir(child);
			else fs.unlink(child);
		}
	}
	return fs.rmdir(dir) != null;
}

function write_stamp(dir, pid) {
	let a = fs.writefile(dir + '/pid', sprintf('%d\n', pid));
	if (a == null) return env_fail(sprintf('写 pid 文件失败：%s/pid（%s）', dir, err_text()));
	let b = fs.writefile(dir + '/since', sprintf('%d\n', time()));
	if (b == null) return env_fail(sprintf('写 since 文件失败：%s/since（%s）', dir, err_text()));
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
 * **不抛异常**；reason='env' 说明是环境问题（目录建不出来、盘满、只读），
 * 调用方应映射成 E_INTERNAL 而不是 E_LOCKED。
 */
export function take(opts) {
	let dir = lockdir(opts);

	// 同进程重入：daemon 里 do_on 内部又调 do_tick 这类路径不该自己卡自己
	if (held != null && held.dir == dir) return { ok: true, dir: dir, pid: held.pid };

	let pid = self_pid();
	if (pid <= 0) return env_fail('取不到自身 pid（读 /proc/self/stat 失败）');

	let pd = ensure_dir(fs.dirname(dir));
	if (!pd.ok) return pd;

	let tmp = sprintf('%s%s%d.%d', dir, NEW_SUFFIX, pid, time());
	clear_dir(tmp);

	let mk = fs.mkdir(tmp);
	if (mk !== true) {
		return env_fail(sprintf('建临时锁目录失败：%s（%s）', tmp, err_text()));
	}
	let ws = write_stamp(tmp, pid);
	if (!ws.ok) {
		clear_dir(tmp);
		return ws;
	}

	let moved = fs.rename(tmp, dir);
	if (moved === true) {
		held = { dir: dir, pid: pid };
		return { ok: true, dir: dir, pid: pid };
	}
	let rerr = err_text();     // 必须紧跟 rename

	// 只有"目标非空"才算被别人占，其余一律环境错误（否则会变成静默死锁）
	if (rerr != E_NOTEMPTY && rerr != E_EXIST) {
		clear_dir(tmp);
		return env_fail(sprintf('rename 到锁目录失败：%s（%s）', dir, rerr));
	}

	let h = holder({ dir: dir });
	if (h != null && h.alive) {
		clear_dir(tmp);
		return { ok: false, reason: 'locked', holder: h };
	}

	// 陈旧锁：把旧目录挪走让位，再抢一次
	let grave = sprintf('%s%s%d.%d', dir, STALE_SUFFIX, pid, time());
	let g = fs.rename(dir, grave);
	if (g !== true) {
		clear_dir(tmp);
		return env_fail(sprintf('接管陈旧锁失败：%s（%s）', dir, err_text()));
	}

	let won = (fs.rename(tmp, dir) === true);
	if (won) {
		held = { dir: dir, pid: pid };
	}
	else {
		clear_dir(tmp);
	}
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
