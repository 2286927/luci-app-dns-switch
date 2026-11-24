'use strict';

// ============================================================
// log.uc —— L0 基础层：syslog 与事件时间线
//
// 承接 v1.0.1 的 log() / ev() / ev_prune()。
//
//   log(msg)     → logger -t dns-switch，**不带 -p**（与 v1.0.1 逐字节一致，
//                  运维 grep 的 syslog 行不变）
//   warn/err     → 新增的分级出口，带 -p user.warn / user.err；
//                  要保 v1.0.1 的消息原样就用 log()，别顺手改成分级
//   ev(kind,...) → 追加 /etc/dns-switch/events.log，**4 列 TSV**（C8）：
//                  ts \t kind \t reason \t detail
//                  写失败静默返回 false，绝不阻断业务（§3.3 事件缝）
//   prune()      → 删掉超过 7 天的事件行
//
// tty 镜像：v1.0.1 的 log() 在 stdout 是终端时多 echo 一遍给人看。
// ucode 没有 isatty，用 /proc/self/fd/1 的 stat 类型近似：
//   终端 = char 设备（实测管道是 fifo）→ 只有 char 才镜像，保持 stdout 不变。
//
// 依赖：sh（logger 走 runq）
// ============================================================

import { runq, quote } from './sh.uc';

let fs = require('fs');

const TAG = 'dns-switch';
const EVENTS = '/etc/dns-switch/events.log';
const KEEP_DAYS = 7;

/** C8 的 kind 枚举：一个不多一个不少 */
export const KINDS = [
	'on', 'off', 'failover', 'recover', 'drift',
	'repair', 'conflict', 'drill', 'rescue', 'snapshot', 'bundle'
];

let logger_path = null;
let tty = null;

function logger_bin() {
	if (logger_path != null) return logger_path;
	if (fs.stat('/usr/bin/logger') != null) logger_path = '/usr/bin/logger';
	else if (fs.stat('/bin/logger') != null) logger_path = '/bin/logger';
	else logger_path = 'logger';
	return logger_path;
}

function is_tty() {
	if (tty != null) return tty;
	tty = false;
	try {
		let st = fs.stat('/proc/self/fd/1');
		if (st != null && st.type == 'char') tty = true;
	} catch (e) {
		tty = false;
	}
	return tty;
}

// 一条事件字段里不能有换行/制表符：v1.0.1 用 tr '\n\r\t' '   ' 逐字符换成空格
// 判 null 用 `=== null`：实测 ucode 的 type(null) 返回 null 本身，不是字符串
function one_line(v) {
	if (v === null) return '';
	let s = (type(v) == 'string') ? v : ("" + v);
	return replace(s, /[\n\r\t]/g, ' ');
}

function syslog(pri, text) {
	let pri_opt = (pri == null) ? '' : (' -p ' + pri);
	runq(sprintf('%s -t %s%s %s', logger_bin(), TAG, pri_opt, quote(text)));
}

export function is_kind(k) {
	for (let i = 0; i < length(KINDS); i++)
		if (KINDS[i] == k) return true;
	return false;
}

/** 普通日志：与 v1.0.1 的 log() 等价 */
export function log(msg) {
	let text = one_line(msg);
	syslog(null, text);
	if (is_tty()) printf('%s\n', text);
	return true;
}

/** 警告：syslog 打 user.warn，终端下走 stderr（不污染 stdout） */
export function warn(msg) {
	let text = one_line(msg);
	syslog('user.warn', '警告：' + text);
	if (is_tty()) fs.stderr.write('警告：' + text + '\n');
	return true;
}

/** 错误：syslog 打 user.err，终端下走 stderr */
export function err(msg) {
	let text = one_line(msg);
	syslog('user.err', '错误：' + text);
	if (is_tty()) fs.stderr.write('错误：' + text + '\n');
	return true;
}

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

/**
 * 记一条事件。opts 只给单测重定向路径用（{ path }），生产调用省略。
 * 返回 true=写成功；false=写失败（调用方**不该**因此中断业务）。
 */
export function ev(kind, reason, detail, opts) {
	if (type(kind) != 'string' || !length(one_line(kind))) return false;

	let path = EVENTS;
	if (opts != null && type(opts) == 'object') {
		if (type(opts.path) == 'string' && length(opts.path)) path = opts.path;
	}

	let k = one_line(kind);
	if (!is_kind(k)) warn(sprintf('未知事件类型 "%s"，事件仍落盘（调用点该改）', k));

	let line = sprintf('%d\t%s\t%s\t%s\n', time(), k, one_line(reason), one_line(detail));
	if (!mkdir_p(fs.dirname(path))) return false;

	let fh = null;
	try {
		fh = fs.open(path, 'a');
	} catch (e) {
		fh = null;
	}
	if (fh == null) return false;

	try {
		fh.write(line);
		fh.close();
	} catch (e) {
		return false;
	}
	return true;
}

/**
 * 只留最近 KEEP_DAYS 天（等价的 awk：NF && $1+0 >= cutoff）。
 * 原子替换：写 .tmp 再 rename，读时间线的人不会看到半个文件。
 */
export function prune(opts) {
	let path = EVENTS;
	let days = KEEP_DAYS;
	if (opts != null && type(opts) == 'object') {
		if (type(opts.path) == 'string' && length(opts.path)) path = opts.path;
		if (type(opts.days) == 'int' && opts.days > 0) days = opts.days;
	}

	let raw = fs.readfile(path);
	if (type(raw) != 'string') return true;   // 没有文件 = 没东西可清

	let cutoff = time() - days * 86400;
	let lines = split(raw, '\n');
	let kept = [];

	for (let i = 0; i < length(lines); i++) {
		let ln = lines[i];
		if (!length(ln)) continue;
		let fields = split(ln, '\t');
		let ts = +fields[0];
		if (ts >= cutoff) push(kept, ln);
	}

	let out = length(kept) ? (join('\n', kept) + '\n') : '';
	let tmp = path + '.tmp';
	if (fs.writefile(tmp, out) == null) return false;
	return fs.rename(tmp, path) != null;
}
