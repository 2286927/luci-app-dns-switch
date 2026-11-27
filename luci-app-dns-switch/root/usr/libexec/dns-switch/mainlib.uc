'use strict';

// ============================================================
// mainlib.uc —— L5：CLI 派发与退出码映射（**可测**）
//
// 拆出来的原因：`main.uc` 是程序式（顶层 `exit(main(ARGV))`），既不能 import
// 也没法单测；而 `rc_of()` 是 C5 六个退出码的**唯一实现**，必须能被断言。
// 所以逻辑搬到这里（导出 main / rc_of），`main.uc` 只剩 3 行薄壳，
// `exit(main(ARGV))` 的字面形式不变，A7 两条判据原样成立。
//
// 退出码（C5）：0 成功 / 1 内部错误 / 2 闸门·冲突 / 3 自检·fw4 / 4 nft·uci / 75 锁
//
// rescue 子命令**不经 ucode**：I3 要求绕过它，由 shim 在调 ucode 之前执行。
// 万一真进来，报错并返回 1——不假装成功。
// ============================================================

import * as sw from './switch.uc';
import * as status from './status.uc';
import * as snapshot from './snapshot.uc';
import * as timeline from './timeline.uc';
import * as bundle from './bundle.uc';

const RC_OK = 0;
const RC_INTERNAL = 1;
const RC_GATE = 2;
const RC_NFT = 4;
const RC_LOCKED = 75;

/** 结果对象 → 退出码。**纯函数**，C5 的唯一实现。 */
export function rc_of(r) {
	if (r == null) return RC_INTERNAL;
	if (r.ok == true) return RC_OK;
	if (r.code == 'E_LOCKED') return RC_LOCKED;
	if (r.code == 'E_PRECOND_GATE' || r.code == 'E_CONFLICT') return RC_GATE;
	if (r.code == 'E_NFT_INVALID' || r.code == 'E_UCI_COMMIT') return RC_NFT;
	return RC_INTERNAL;
}

function say(s) { printf('%s\n', s); }

function usage() {
	say('用法：dns-switch <子命令>');
	say('  on | off | status | tick | apply-intent | drill');
	say('  snapshot [save|list|restore <id>|diff <a> <b>]');
	say('  timeline [N] | bundle | version | rescue');
	return RC_OK;
}

function do_snapshot(argv, opts) {
	let sub = (length(argv) > 0) ? argv[0] : 'list';
	if (sub == 'save') {
		let r = snapshot.save(opts);
		if (r.ok == true) say(sprintf('OK   %s', r.id));
		return rc_of(r);
	}
	if (sub == 'restore') {
		let id = (length(argv) > 1) ? argv[1] : '';
		if (!length(id)) { say('缺快照 id'); return RC_INTERNAL; }
		return rc_of(snapshot.restore(id, opts));
	}
	if (sub == 'diff') {
		if (length(argv) < 3) { say('用法：snapshot diff <a> <b>'); return RC_INTERNAL; }
		printf('%s', snapshot.diff(argv[1], argv[2], opts));
		return RC_OK;
	}
	let list = snapshot.list(opts);
	if (!length(list)) { say('还没有快照。执行 dns-switch snapshot save 建一个。'); return RC_OK; }
	for (let i = 0; i < length(list); i++) {
		printf('%-18s %-8s %s\n', list[i].id, list[i].mode,
			length(list[i].upstream) ? list[i].upstream : '空');
	}
	return RC_OK;
}

/** 派发。opts 透传给各模块（测试缝：confdir / io / state_dir / lock_dir）。 */
export function main(argv, opts) {
	let o = (opts != null && type(opts) == 'object') ? opts : null;
	let cmd = (type(argv) == 'array' && length(argv) > 0) ? argv[0] : 'status';
	let rest = (type(argv) == 'array' && length(argv) > 1) ? slice(argv, 1) : [];

	if (cmd == 'on') return rc_of(sw.on(o));
	if (cmd == 'off') return rc_of(sw.off(o));
	if (cmd == 'drill') return rc_of(sw.drill(o));
	if (cmd == 'apply-intent') return rc_of(sw.apply_intent(o));
	if (cmd == 'tick') return rc_of(sw.tick(o));
	if (cmd == 'snapshot') return do_snapshot(rest, o);

	if (cmd == 'status') {
		let so = status.collect(o);
		printf('%s', status.render_text(so));
		return rc_of(so);
	}
	if (cmd == 'timeline') {
		let n = (length(rest) > 0) ? +rest[0] : 20;
		printf('%s', timeline.render(n, o));
		return RC_OK;
	}
	if (cmd == 'bundle') {
		let r = bundle.collect(o);
		if (r.ok != true) return rc_of(r);
		say(sprintf('OK   %s（%d 字节）', r.path, r.size));
		return RC_OK;
	}
	if (cmd == 'version') { say('dns-switch 1.1.0'); return RC_OK; }
	if (cmd == 'rescue') {
		say('rescue 不经 ucode：请用 /usr/bin/dns-switch rescue（由 shim 处理）');
		return RC_INTERNAL;
	}
	return usage();
}
