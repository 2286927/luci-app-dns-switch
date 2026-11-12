'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require poll';
'require fs';

function ts(v) {
	var n = parseInt(v || '0', 10);
	if (!n)
		return '—';
	var d = new Date(n * 1000);
	var p = function(x) { return (x < 10 ? '0' : '') + x; };
	return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) +
		' ' + p(d.getHours()) + ':' + p(d.getMinutes());
}

return view.extend({
	load: function() {
		return uci.load('dns_switch');
	},

	// 有待提交的改动吗？保存过程中轮询绝不能动 uci 缓存。
	hasPendingUci: function() {
		try {
			var c = uci.state && uci.state.changes;
			if (!c)
				return false;
			for (var k in c)
				for (var s in c[k])
					for (var o in c[k][s])
						return true;
			return false;
		} catch (e) {
			return false;
		}
	},

	readState: function() {
		// unload 是必需的——不 unload 就永远读到缓存里的旧状态，SSH 或别的
		// 页面改了配置这边看不见。但它会顺带丢掉 pending changes：
		// 若正好撞上「用户在改参数准备保存」，表单字段会回落到空值，
		// 保存时把这些空值写回去就等于删了配置（2026-11-11 丢过
		// fallback_dns6 和 isp_list4/6，查了很久才定位到这条路径）。
		// 所以有未提交改动时，宁可用缓存也不动它。
		if (!this.hasPendingUci())
			uci.unload('dns_switch');
		return uci.load('dns_switch').then(function() {
			var g = function(sec, opt) { return uci.get('dns_switch', sec, opt) || ''; };
			return {
				mode: g('settings', 'mode') || 'off',
				effective: g('status', 'effective') || 'off',
				probe: g('status', 'probe') || 'unknown',
				adh: (g('settings', 'adh_ip') || '172.16.1.2') + ':' + (g('settings', 'adh_port') || '3030'),
				changed: g('status', 'last_change'),
				error: g('status', 'error'),
				conflict: g('status', 'conflict') || 'none',
				conflictBy: g('status', 'conflict_by'),
				conflictMsg: g('status', 'conflict_msg'),
				conflictFix: g('status', 'conflict_fix'),
				// 探测依赖：留空/未知一律当正常（不打扰）；
				// 只有守护进程明确写了 no-curl 才提示。
				dep: g('status', 'dep')
			};
		}).then(function(st) {
			// dep 由守护每轮 tick（55 秒）写一次；下面这段是页面侧的加速：
			// 直接看一眼二进制，命中就原地翻案，刷新即可看到提示消失，
			// 甚至不刷新也会在下一轮 poll（5 秒）翻案。
			//
			// 用 fs.stat 而不是 fs.access：本版 LuCI（25.12）的 fs.js 只有
			// exec/list/read/stat，**没有 access**。两者语义一致（成功 resolve
			// / 失败 reject），换成 stat 后这段在本版才真正执行，ACL 里那条
			// /usr/bin/curl 只读授权也随之从空转变成用得上。
			//
			// 无论走不走得到，都必须"只有确证存在才翻案"：查不到（ACL 未授权、
			// ubus 不可用、非标准路径）就保留守护的结论，绝不把页面搞崩。
			if (st.dep !== 'no-curl' || typeof fs.stat !== 'function')
				return st;
			return fs.stat('/usr/bin/curl').then(function(r) {
				if (r !== false)
					st.dep = 'ok';
				return st;
			}, function() {
				return st;
			});
		});
	},

	// 整页只需要读懂这一句
	headline: function(st) {
		// 端口被占时，下面所有状态都是假的：劫持链在位、上游写着 ADH，
		// 但流量根本没进 dnsmasq。所以这一条必须盖过其它结论。
		if (st.conflict === 'block')
			return { text: _('有别的服务抢走了 DNS 端口，现在切换不会生效'), color: 'var(--error-color-high)' };
		if (st.effective === 'on')
			return { text: _('全屋正在使用 AdGuardHome'), color: 'var(--success-color-high)' };
		if (st.effective === 'failover')
			return { text: _('AdGuardHome 不可用，已临时改用运营商 DNS'), color: 'var(--warning-color-high)' };
		if (st.mode === 'on')
			return { text: _('已开启，但当前没有生效'), color: 'var(--error-color-high)' };
		return { text: _('全屋正在使用运营商 DNS'), color: 'var(--text-color-medium)' };
	},

	subline: function(st) {
		return [
			st.adh,
			st.probe === 'ok' ? _('ADH 在线') :
				st.probe === 'fail' ? _('ADH 离线') : _('ADH 状态未知'),
			_('最后切换 ') + ts(st.changed)
		].join('  ·  ');
	},

	// 端口冲突单独一块：它推翻的是上面所有结论，所以给出原因和能直接粘的命令
	conflictBox: function(st) {
		var block = (st.conflict === 'block');
		var bg = block ? 'rgba(200,60,60,.09)' : 'rgba(220,150,40,.10)';
		var bd = block ? 'rgba(200,60,60,.35)' : 'rgba(220,150,40,.38)';

		var rows = [
			E('div', { 'style': 'font-size:.92em;line-height:1.6' }, st.conflictMsg),
			E('div', {
				'style': 'margin-top:.35em;font-size:.85em;line-height:1.55;color:var(--text-color-medium)'
			}, block
				? _('端口被别人占着时，劫持会把查询送到别人的解析器上，症状是「看着开了，广告还在」。')
				: _('现在还能用，但路由器重启后可能换人，建议顺手处理掉。'))
		];

		if (st.conflictFix)
			rows.push(E('div', {
				'style': 'margin-top:.7em;padding:.6em .8em;border-radius:4px;' +
					'background:rgba(128,128,128,.16);font-family:monospace;font-size:.82em;' +
					'line-height:1.5;word-break:break-all;user-select:all'
			}, st.conflictFix));

		return E('div', {
			'style': 'margin-top:.9em;padding:.8em 1em;border-radius:4px;' +
				'background:' + bg + ';border:1px solid ' + bd
		}, rows);
	},

	// 缺 curl 不是故障，只是探测精度降了一档：装不装都能正常切换，
	// 所以不弹窗、不拦按钮，只在卡片里放一条会自己消失的提示。
	// curl 是独立包，luci-base 不拉它，精简固件上很常见——这也是有意
	// 不把它写进依赖的原因（为了一个探测端口让整个包多拖 libcurl4，不划算）。
	depNote: function() {
		return E('div', {
			'style': 'margin-top:.9em;padding:.8em 1em;border-radius:4px;' +
				'background:rgba(220,150,40,.10);border:1px solid rgba(220,150,40,.32)'
		}, [
			E('div', { 'style': 'font-size:.92em;line-height:1.6' },
				_('未检测到 curl：探测精度降低')),
			E('div', {
				'style': 'margin-top:.35em;font-size:.85em;line-height:1.55;color:var(--text-color-medium)'
			}, _('现在只按 DNS 解析判断 AdGuardHome 是否可用，切换和自动降级都照常工作。装上 curl 后刷新页面即会消失，最迟约一分钟内也会自动消失，不用重启服务，也不用重启设备。')),
			E('div', {
				'style': 'margin-top:.7em;padding:.6em .8em;border-radius:4px;' +
					'background:rgba(128,128,128,.16);font-family:monospace;font-size:.82em;' +
					'line-height:1.6;white-space:pre-wrap;word-break:break-all;user-select:all'
			}, 'apk add curl          # 25.12 及以后\nopkg install curl     # 23.05 / 24.10')
		]);
	},

	card: function(st) {
		var h = this.headline(st);
		var rows = [
			E('div', { 'style': 'font-size:1.35em;font-weight:500;line-height:1.45;color:' + h.color }, h.text)
		];

		// 端口被占时真话是"实际没生效"，再写"正在使用 AdGuardHome"是自欺
		if (st.conflict !== 'block')
			rows.push(E('div', {
				'style': 'margin-top:.6em;font-size:.9em;color:var(--text-color-medium)'
			}, this.subline(st)));

		if (st.conflict !== 'none')
			rows.push(this.conflictBox(st));

		if (st.error && st.conflict !== 'block')
			rows.push(E('div', {
				'style': 'margin-top:.6em;font-size:.9em;color:var(--error-color-high)'
			}, st.error));

		if (st.dep === 'no-curl')
			rows.push(this.depNote());

		var on = (st.mode === 'on');

		var footer = E('div', {
			'style': 'display:flex;align-items:center;gap:1em;margin-top:1.1em;padding-top:1em;' +
				'border-top:1px solid rgba(128,128,128,.22)'
		}, [
			E('span', { 'style': 'font-size:.85em;color:var(--text-color-medium);flex:1;line-height:1.5' },
				st.conflict === 'block'
					? _('先按上面的命令把端口让回来，再回来切换')
					: on ? _('切换时会先探测可用性，失败自动回滚，不会把网络弄断')
						: _('切换前会确认 AdGuardHome 真的可用，不可用就拒绝')),
			E('button', {
				'class': on ? 'btn cbi-button' : 'btn cbi-button cbi-button-apply important',
				'click': ui.createHandlerFn(this, 'handleToggle')
			}, on ? _('改用运营商 DNS') : _('启用 AdGuardHome DNS'))
		]);

		return E('div', {
			'style': 'padding:1.3em 1.4em 1.2em;border:1px solid rgba(128,128,128,.35);' +
				'border-left:3px solid ' + h.color + ';border-radius:6px;' +
				'background:rgba(128,128,128,.07)'
		}, rows.concat([ footer ]));
	},

	render: function() {
		var self = this;
		var holder = E('div', {});
		this._holder = holder;
		var lastKey = null;

		var paint = function(st) {
			// dep 必须进 key：漏了它，状态里的 dep 变了但 key 不变，paint 直接
			// return，缺 curl 的提示就永远是「画上去就再也下不来」。
			var key = JSON.stringify([st.mode, st.effective, st.probe, st.changed,
				st.error, st.conflict, st.conflictMsg, st.conflictFix, st.dep]);
			if (key === lastKey)
				return;
			lastKey = key;
			holder.innerHTML = '';
			holder.appendChild(self.card(st));
		};

		this.readState().then(paint);
		poll.add(function() {
			if (self.busy)
				return;
			return self.readState().then(paint);
		}, 5);

		// 参数沿用 LuCI 原生 CBI：校验、保存、应用都是它自己的实现
		var m = new form.Map('dns_switch', null, null);
		this.map = m;

		var s = m.section(form.TypedSection, 'settings');
		s.anonymous = true;
		s.addremove = false;

		var o;

		o = s.option(form.Value, 'adh_ip', _('AdGuardHome 地址'));
		o.datatype = 'ip4addr';
		o.rmempty = false;

		o = s.option(form.Value, 'adh_port', _('管理端口'));
		o.datatype = 'port';
		o.placeholder = '3030';
		o.rmempty = false;

		o = s.option(form.ListValue, 'upstream_mode', _('上游来源'));
		o.value('auto', _('跟随运营商自动读取'));
		o.value('manual', _('手动指定'));
		o.default = 'auto';

		o = s.option(form.Value, 'isp_list4', _('手动上游 IPv4'));
		o.placeholder = '202.103.224.68 202.103.225.68';
		o.description = _('空格分隔，第一个优先。上游来源选「自动」时忽略此项');

		o = s.option(form.Value, 'isp_list6', _('手动上游 IPv6'));
		o.placeholder = '2400:3200::1';
		o.description = _('只填 IPv6，没有就留空');

		o = s.option(form.Value, 'fallback_dns', _('备用 DNS IPv4'));
		o.datatype = 'ip4addr';
		o.placeholder = '172.16.5.5';
		o.description = _('ADH 不可用时客户端回落到这里，留空表示只下发路由器');

		o = s.option(form.Value, 'fallback_dns6', _('备用 DNS IPv6'));
		o.datatype = 'ip6addr';
		o.placeholder = '2400:3200::1';
		o.description = _('IPv6 客户端通过 RDNSS 拿到这个地址。留空则不下发——避免客户端拿到不可达的 v6 DNS 而拖慢解析');

		o = s.option(form.Value, 'adh_mac', _('AdGuardHome 网卡 MAC'));
		o.placeholder = 'aa:bb:cc:dd:ee:ff';
		o.description = _('留空自动探测。换设备后填这里，用于放行 ADH 自己的出站查询');

		o = s.option(form.ListValue, 'dot853', _('加密 DNS（853）'));
		o.value('allow', _('放行'));
		o.value('block', _('拦截，强制回落明文'));
		o.default = 'allow';

		o = s.option(form.Value, 'probe_domain', _('探测域名'));
		o.datatype = 'hostname';
		o.placeholder = 'www.baidu.com';
		o.description = _('用来判断 ADH 是否真的能解析');

		return m.render().then(L.bind(function(formEl) {
			return E('div', {}, [
				E('h2', { 'style': 'margin-bottom:.2em' }, _('DNS 网关切换')),
				E('div', { 'class': 'cbi-section-descr', 'style': 'margin-bottom:1.4em' },
					_('让全屋设备的 DNS 走 AdGuardHome，或者交还给运营商。')),

				holder,

				E('details', { 'style': 'margin-top:2.2em' }, [
					E('summary', {
						'style': 'cursor:pointer;font-weight:500;padding:.5em 0;outline:none'
					}, _('高级参数'), E('span', {
						'style': 'font-weight:400;color:var(--text-color-medium);font-size:.9em;margin-left:.5em'
					}, _('换设备、改上游时才需要动'))),

					E('div', { 'style': 'margin-top:1em' }, [
						formEl,
						E('div', { 'style': 'text-align:right;margin:1.2em 0 .5em' }, [
							E('button', {
								'class': 'btn cbi-button cbi-button-save',
								'click': ui.createHandlerFn(this, 'handleSaveAll')
							}, _('保存参数'))
						])
					])
				])
			]);
		}, this));
	},

	// 主按钮只给"下一步"，不做二选一
	handleToggle: function() {
		var self = this;
		return this.readState().then(function(st) {
			var turningOn = (st.mode !== 'on');

			// 端口被占时先拦一下：硬切必然走到 rc=2，不如把修复命令直接给他
			if (turningOn && st.conflict === 'block')
				return self.warnConflict(st);

			var lines = turningOn ? [
				_('将把 DHCP 下发的 DNS 指向 AdGuardHome，并把路由器上游改为 ADH 优先、运营商兜底。'),
				_('会先探测 ADH 是否可用，不可用就拒绝，现有配置一个字节都不改。')
			] : [
				_('将撤回 53 端口劫持，路由器上游交还运营商，DHCP 不再下发 ADH 地址。'),
				_('恢复后 AdGuardHome 的过滤和统计对客户端不再生效。')
			];

			return self.confirm(
				turningOn ? _('启用 AdGuardHome DNS') : _('改用运营商 DNS'),
				lines,
				turningOn ? _('确认启用') : _('确认切换')
			).then(function(ok) {
				if (!ok)
					return;
				return self.applyMode(turningOn ? 'on' : 'off');
			});
		});
	},

	warnConflict: function(st) {
		var self = this;
		var body = [
			E('p', {}, st.conflictMsg),
			E('p', { 'style': 'font-size:.9em;color:var(--text-color-medium)' },
				_('修好之后再点一次。现在硬切只会白跑一轮，最后照样退回原生。'))
		];
		if (st.conflictFix)
			body.splice(1, 0, E('div', {
				'style': 'margin:.6em 0;padding:.6em .8em;border-radius:4px;' +
					'background:rgba(128,128,128,.16);font-family:monospace;font-size:.85em;' +
					'line-height:1.5;word-break:break-all;user-select:all'
			}, st.conflictFix));

		return new Promise(function(resolve) {
			ui.showModal(_('先处理端口占用'), body.concat([
				E('div', { 'class': 'right' }, [
					E('button', {
						'class': 'btn',
						'click': function() { ui.hideModal(); resolve(false); }
					}, _('知道了')),
					' ',
					E('button', {
						'class': 'btn cbi-button',
						'click': function() { ui.hideModal(); resolve(true); }
					}, _('仍然尝试'))
				])
			]));
		}).then(function(tryAnyway) {
			if (tryAnyway)
				return self.applyMode('on');
		});
	},

	confirm: function(title, lines, okText) {
		return new Promise(function(resolve) {
			ui.showModal(title, [
				E('div', {}, lines.map(function(l) { return E('p', {}, l); })),
				E('div', { 'class': 'right' }, [
					E('button', {
						'class': 'btn',
						'click': function() { ui.hideModal(); resolve(false); }
					}, _('取消')),
					' ',
					E('button', {
						'class': 'btn cbi-button cbi-button-apply',
						'click': function() { ui.hideModal(); resolve(true); }
					}, okText)
				])
			]);
		});
	},

	// rpcd 在没有任何待提交改动时会以 ubus code 5 拒绝 apply。
	// 用户连点两次保存必然撞上——这不是失败，不该弹红条。
	//
	// 注意不能先判断 uci.state.changes 再决定跳不跳：map.save() 会把改动
	// 提交进 rpcd 的 session delta 并清空本地 changes，看本地状态必然为空，
	// 一跳过 apply 参数就没真正落盘。只能老老实实 apply，再按错误码兜底。
	//
	// 另外 25.12 的 uci 模块没有公开 confirm()（apply 内部已自动确认），
	// 再调一次只会得到 TypeError。
	applyUci: function() {
		return uci.apply().catch(function(e) {
			var msg = '';
			try { msg = (e && (e.message || e.toString())) || String(e) || ''; } catch (_) {}
			if (/code 5|无已接收数据|no data/i.test(msg))
				return;
			throw e;
		});
	},

	applyMode: function(mode) {
		var self = this;
		this.busy = true;

		ui.showModal(_('正在切换并自检'), [
			E('p', { 'class': 'spinning' },
				_('切换后会验证解析，失败自动回滚。请稍候，最长约 45 秒。'))
		]);

		// LuCI 25.12 起 uci.set 只写本地 state.changes，apply 不负责提交。
		// 少了 save() 这一步，rpcd 收到的是空 delta，报 ubus code 5「无已接收数据」。
		return Promise.resolve()
			.then(function() { uci.set('dns_switch', 'settings', 'mode', mode); })
			.then(function() { uci.set('dns_switch', 'settings', 'request_at', String(Date.now())); })
			.then(function() { return uci.save(); })
			.then(function() { return self.applyUci(); })
			.then(function() { return self.waitFor(mode); })
			.then(function(st) {
				ui.hideModal();
				if (mode === 'on' && st.effective === 'on')
					ui.addNotification(null, E('p', {}, _('已启用，全屋 DNS 走 AdGuardHome。')), 'info');
				else if (mode === 'off' && st.effective === 'off')
					ui.addNotification(null, E('p', {}, _('已切换，全屋 DNS 交由运营商解析。')), 'info');
				else
					ui.addNotification(null, E('p', {},
						_('切换未生效：') + (st.error || _('可 SSH 执行 dns-switch status 查看'))), 'danger');
				return self.readState().then(function(s2) {
					if (self._holder) {
						self._holder.innerHTML = '';
						self._holder.appendChild(self.card(s2));
					}
				});
			})
			.catch(function(e) {
				ui.hideModal();
				ui.addNotification(null, E('p', {}, _('调用失败：') + e), 'danger');
			})
			.then(function() {
				self.busy = false;
			});
	},

	handleSaveAll: function() {
		var self = this;
		this.busy = true;
		return this.map.save().then(function() {
			return self.applyUci();
		}).then(function() {
			ui.addNotification(null, E('p', {}, _('已保存，正在按新参数重新下发。')), 'info');
			return self.readState().then(function(st) {
				if (self._holder) {
					self._holder.innerHTML = '';
					self._holder.appendChild(self.card(st));
				}
			});
		}).catch(function(e) {
			ui.addNotification(null, E('p', {}, _('保存失败：') + e), 'danger');
		}).then(function() {
			self.busy = false;
		});
	},

	waitFor: function(mode) {
		var self = this;
		var t0 = Date.now();

		return new Promise(function(resolve, reject) {
			(function loop() {
				self.readState().then(function(st) {
					var elapsed = Date.now() - t0;
					var done = (mode === 'on' && (st.effective === 'on' || st.effective === 'failover')) ||
						(mode === 'off' && st.effective === 'off') ||
						// 脚本把意图退回了（闸门拒绝 / 端口冲突 / 自检回滚）。
						// 不认这条就会干等到超时，用户看不到失败原因。
						(elapsed > 1500 && st.mode !== mode);
					if (done)
						return resolve(st);
					if (elapsed > 45000)
						return reject(_('等待超时，服务可能没响应'));
					window.setTimeout(loop, 1500);
				}).catch(reject);
			})();
		});
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
