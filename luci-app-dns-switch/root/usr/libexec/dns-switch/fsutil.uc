'use strict';

// ============================================================
// fsutil.uc —— L0 基础层：文件系统小工具
//
// 从 lock.uc 拆出来的（IMPL-NOTES N23：lock/config 超 250 行先拆纯工具函数）。
// 只放松散的、与业务无关的 fs 操作，不许出现"锁""配置"这类概念。
//
// 消费者：lock.uc（现有）→ nft.uc / snapshot.uc（P3 用原子写时会加 export）。
// 注意：**没有消费者的 export 不要提前加**，SPEC §3.3 的孤儿门禁会判 FAIL。
//
// ------------------------------------------------------------
// fs.error() 的实测语义：**读即清（消费型）**，与中间发生过几次别的调用无关。
//   T1 连续读两次           → 'File exists' 然后 null      ← 读一次就清空
//   T4 失败 → fs.stat → 读  → 'File exists'                ← stat 不清
//   T5 失败 → 成功调用 → 读 → 'File exists'                ← 成功也不清
//   T2 再失败一次 → 读      → 新文案覆盖旧文案
//
// 所以 `fs.error() != null` 双向都会骗人：
//   失败之后又成功过     → 旧文案还在 ⇒ 被当成失败
//   之前被谁读过一次     → null       ⇒ 被当成成功
// 后一种最阴：任何人（哪怕只是加一行诊断日志）读一次，后面所有判断全部失效。
//
// 规则（N21）：**fs.error() 只许用来拼 message / 写日志，严禁进控制流**。
// 控制流一律「返回值 + fs.stat 复核」——本文件里 err_msg() 就是唯一出口。
//
// 其它实测：
//   fs.mkdir 对「已存在」和「父目录缺失」都返回 null（所以不比文案，stat 复核）
//   fs.rmdir / fs.unlink 对不存在的路径返回 null、**不抛异常**
//   rename：目录→已存在空目录 = 成功顶替；目录→已存在非空目录 = null
//   rename：文件→已存在空目录 = null + 'Is a directory'；文件→已存在文件 = 成功替换
//
// 依赖：fs（不 import 任何 ./x.uc）
// ============================================================

let fs = require('fs');

/**
 * 取最近一次失败的**系统文案**，只用于拼错误消息。
 * 严禁用它判断成败：读即清，且任何人读过一次就没了（见文件头）。
 */
export function err_msg() {
	let e = fs.error();
	if (type(e) == 'string' && length(e)) return e;
	return 'unknown';
}

/**
 * mkdir -p（fs.mkdir 不建父目录，实测）。
 * 成功 → { ok:true }；失败 → { ok:false, message }（message 里带系统文案）。
 * 已存在且确实是目录 → 算成功（并发抢建同一目录是正常场景）。
 */
export function ensure_dir(path) {
	if (type(path) != 'string' || !length(path) || path == '/') return { ok: true };

	let st = fs.stat(path);
	if (st != null && st.type == 'directory') return { ok: true };

	let parent = fs.dirname(path);
	if (parent == path) return { ok: false, message: sprintf('无法创建目录：%s', path) };

	let pd = ensure_dir(parent);
	if (!pd.ok) return pd;

	let r = fs.mkdir(path);
	if (r === true) return { ok: true };
	let why = err_msg();                  // 只拼消息，不参与判断
	let st2 = fs.stat(path);              // 判断靠 stat 复核
	if (st2 != null && st2.type == 'directory') return { ok: true };   // EEXIST 且确实是目录
	return { ok: false, message: sprintf('创建目录失败：%s（%s）', path, why) };
}

/** 读一个十进制整数文件（pid/since 这类）。不存在或不是纯数字 → null。 */
export function read_int(path) {
	let raw = fs.readfile(path);
	if (type(raw) != 'string') return null;
	let t = trim(raw);
	if (match(t, /^-?[0-9]+$/) == null) return null;
	return +t;
}

/**
 * 清一个目录（不跟随软链，最多两级）。路径不存在也算成功。
 * 路径是普通文件 → unlink 掉。返回 true = 现在的确什么都没有了。
 */
export function clear_dir(dir) {
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
