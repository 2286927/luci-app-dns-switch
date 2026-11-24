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
//      —— 目标已存在且非空时 rename 必然失败（实测 dir→nonempty = null），
//         这就是"只有一个人能进去"的判据；目标若是空目录，rename 直接顶替，也对
//   3. rename 失败 → 看持锁者活没活：
//        活着        → return false（正常抢占失败，不抛异常）
//        已死        → 把旧目录 rename 到 .stale.<pid>.<ts> 让位，再抢一次
//      两个进程同时判陈旧时，rename/mkdir 只有一个能成功，输的那个 return false
//
// 存活判定：/proc/<pid> 是否存在（fs.stat，实测不存在返回 null）。
// 不做 pid 复用校验（真机上极端场景：锁持有者被 kill 后 pid 立刻被别的进程占用，
// 会多等一次 tick，不会错乱状态）——记在注记里，别当已知缺陷反复排查。
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

let held = null;    // { dir, pid }：本进程当前持有的锁
let mypid = null;

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

// fs.mkdir 不建父目录（实测：父目录缺失 → null），所以自己来
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
	if (fs.writefile(dir + '/pid', sprintf('%d\n', pid)) == null) return false;
	return fs.writefile(dir + '/since', sprintf('%d\n', time())) != null;
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
 * 抢锁。成功 true，被占/出错 false（**不抛异常**，调用方按 E_LOCKED 处理）。
 */
export function take(opts) {
	let dir = lockdir(opts);

	// 同进程重入：daemon 里 do_on 内部又调 do_tick 这类路径不该自己卡自己
	if (held != null && held.dir == dir) return true;

	let pid = self_pid();
	if (pid <= 0) return false;
	if (!mkdir_p(fs.dirname(dir))) return false;

	let tmp = sprintf('%s%s%d.%d', dir, NEW_SUFFIX, pid, time());
	clear_dir(tmp);
	if (fs.mkdir(tmp) !== true) return false;
	if (!write_stamp(tmp, pid)) {
		clear_dir(tmp);
		return false;
	}

	if (fs.rename(tmp, dir) === true) {
		held = { dir: dir, pid: pid };
		return true;
	}

	// 已被占：活人持锁就老实退出
	let h = holder({ dir: dir });
	if (h != null && h.alive) {
		clear_dir(tmp);
		return false;
	}

	// 陈旧锁：把旧目录挪走让位，再抢一次
	let grave = sprintf('%s%s%d.%d', dir, STALE_SUFFIX, pid, time());
	if (fs.rename(dir, grave) !== true) {
		clear_dir(tmp);
		return false;
	}

	let won = (fs.rename(tmp, dir) === true);
	if (won) held = { dir: dir, pid: pid };
	else clear_dir(tmp);
	clear_dir(grave);
	return won;
}

/**
 * 放锁。真的放开 / 本来就没拿着都返回 true；
 * 发现锁已不归自己（被别的进程当陈旧锁接管）返回 false 且**不动**别人的目录。
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
		if (owner == null || pid <= 0 || owner != pid) return false;
	}

	return clear_dir(dir);
}
