'use strict';

// ============================================================
// sh.uc —— L0 基础层：外部命令执行
//
// 承接 v1.0.1 里的 `$(cmd)` 与 `$(cmd 2>/dev/null)`：
//   * 只取 stdout；stderr 默认透传（与 shell 同语义，daemon 里会进 procd 日志）
//   * 尾部换行剥掉（shell 的 $(...) 也是这么干的）
//   * 退出码原样带回，不做"成功/失败"二值化
//
// 实测结论（r68s / ImmortalWrt 25.12 / ucode 2026.10.28）：
//   * ucode **没有** exec / system 原语，fs.popen 是唯一出口；popen 走 /bin/sh -c
//   * fs.popen(...).close() 返回 **int** 退出码：
//       - 正常          0..255
//       - 命令不存在    127
//       - 被信号杀死    负数（`kill -9 $$` → -9）
//     所以 rc 不能当布尔用，也必须允许负数
//   * popen 不会把子进程 stderr 收进管道，要收必须显式写 `2>&1`
//
// 依赖：fs（无内部依赖，故本文件不 import 任何 ./x.uc）
// ============================================================

let fs = require('fs');

const RC_ENOENT = 127;

// 尾部所有换行都算（shell 的 $(...) 只吃 \n；设备上输出不含 \r，
// 这个差异不可观测，而多吃掉 \r 对 events.log 的 TSV 更安全）
const TRAILING_EOL = /[\r\n]+$/;

function exec(cmd, drop_stderr) {
	let text = (type(cmd) == 'string') ? cmd : ("" + cmd);
	if (drop_stderr) text = text + ' 2>/dev/null';

	let pipe = null;
	try {
		pipe = fs.popen(text, 'r');
	} catch (e) {
		pipe = null;
	}
	if (pipe == null) return { rc: RC_ENOENT, out: '' };

	// 先读干净再 close：反序会在输出超过管道缓冲（64K）时死锁
	let out = '';
	try {
		out = pipe.read('all');
	} catch (e) {
		out = '';
	}

	let rc = RC_ENOENT;
	try {
		let got = pipe.close();
		if (type(got) == 'int') rc = got;
	} catch (e) {
		rc = RC_ENOENT;
	}

	if (type(out) != 'string') out = '';
	return { rc: rc, out: replace(out, TRAILING_EOL, '') };
}

/**
 * 跑一条命令，返回 { rc, out }。stderr 透传。
 * out 已剥掉尾部换行，可能为空串但不为 null。
 */
export function run(cmd) {
	return exec(cmd, false);
}

/**
 * 安静版 run：丢弃 stderr（对应 shell 里的 `2>/dev/null`）。
 * 典型场景：`uci -q get ...`、`logger`、探测类命令。
 */
export function runq(cmd) {
	return exec(cmd, true);
}

/**
 * 合成单引号字面量，供拼命令行用。
 * 内部单引号按 POSIX 惯例写成 '\''，实测 replace 结果正确。
 *
 * 注意：判 null **不能**写 type(s) == 'null' —— 实测 ucode 的 type(null)
 * 返回的是 null 本身（不是字符串 "null"），那种写法永远为假。
 */
export function quote(s) {
	if (s === null) return "''";
	if (type(s) != 'string') s = "" + s;
	return "'" + replace(s, /'/g, "'\\''") + "'";
}
