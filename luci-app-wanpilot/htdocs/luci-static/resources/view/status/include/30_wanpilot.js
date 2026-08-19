// WANPilot overview widget for the LuCI Status -> Overview page.
'use strict';
'require baseclass';
'require rpc';
'require ui';
'require dom';

const callStatus = rpc.declare({
	object: 'wanpilot',
	method: 'status'
});

const callSwitch = rpc.declare({
	object: 'wanpilot',
	method: 'switch',
	params: [ 'interface' ]
});

const callProbe = rpc.declare({
	object: 'wanpilot',
	method: 'probe',
	params: [ 'interface', 'target' ]
});

const DEFAULT_PROBE_INTERVAL_MS = 10000;
const STATUS_INTERVAL_MS = 15000;
const PROBE_CACHE_KEY = 'wanpilot.probe-cache.v1';

function isTrue(value) {
	return value === true || value === 1 || value === '1' || value === 'true';
}

function getProbeIntervalMs(value) {
	var seconds = Number(value);
	if (!isFinite(seconds) || seconds <= 0)
		return DEFAULT_PROBE_INTERVAL_MS;
	return Math.max(1000, Math.round(seconds * 1000));
}

function formatIPList(list) {
	if (!Array.isArray(list) || list.length === 0)
		return '-';
	var clean = [];
	for (var i = 0; i < list.length; i++) {
		if (!list[i])
			continue;
		var ip = String(list[i]);
		if (ip.indexOf('/') !== -1)
			ip = ip.substring(0, ip.indexOf('/'));
		clean.push(ip);
		if (clean.length >= 2)
			break;
	}
	return clean.length ? clean.join(', ') : '-';
}

function formatList(list) {
	if (!Array.isArray(list) || list.length === 0)
		return '-';
	return list.map(String).filter(function(s) { return s.length > 0; }).join(', ');
}

function getConnectionLabel(item) {
	if (!isTrue(item.up) && !isTrue(item.available))
		return { text: _('OFFLINE'), cls: 'ifacebadge ifacebadge-down' };
	switch (String(item.online_state || '')) {
		case 'online':
			return { text: _('ONLINE'), cls: 'ifacebadge ifacebadge-up' };
		case 'checking':
			return { text: _('CHECKING'), cls: 'ifacebadge ifacebadge-unknown' };
		case 'no_route':
			return { text: _('NO ROUTE'), cls: 'ifacebadge ifacebadge-unknown' };
		case 'disabled':
			return { text: _('DISABLED'), cls: 'ifacebadge ifacebadge-down' };
		case 'stopped':
			return { text: _('STOPPED'), cls: 'ifacebadge ifacebadge-down' };
		case 'unsupported':
			return { text: _('UNSUPPORTED'), cls: 'ifacebadge ifacebadge-down' };
		default:
			return isTrue(item.online)
				? { text: _('ONLINE'), cls: 'ifacebadge ifacebadge-up' }
				: { text: _('CONNECTED'), cls: 'ifacebadge ifacebadge-unknown' };
	}
}

function matchProbeResult(reply, target) {
	if (!reply || !Array.isArray(reply.results))
		return null;
	for (var i = 0; i < reply.results.length; i++) {
		var r = reply.results[i];
		if (r && r.name === target)
			return r;
	}
	return null;
}

function formatProbeText(label, result) {
	if (!result)
		return label + ':—';
	var ok = isTrue(result.ok);
	var rtt = String(result.rtt_ms || '0');
	var code = String(result.http_code || '0');
	if (!ok)
		return label + ':FAIL';
	if (rtt !== '0' && rtt !== '')
		return label + ':' + rtt + 'ms';
	return label + ':' + (code && code !== '0' ? code : 'OK');
}

function getCardStyle(item) {
	var style = 'display:flex;flex-direction:column;justify-content:space-between;'
		+ 'gap:0.65rem;box-sizing:border-box;width:280px;max-width:100%;min-width:0;flex:0 1 280px;'
		+ 'padding:0.85rem;border:1px solid rgba(127,127,127,0.32);border-radius:5px;'
		+ 'background-color:transparent;';
	if (isTrue(item.active))
		style += 'border-color:#16a34a;background-color:rgba(22,163,74,0.05);';
	return style;
}

function loadProbeCache() {
	try {
		var value = JSON.parse(window.localStorage.getItem(PROBE_CACHE_KEY) || '{}');
		return value && typeof value === 'object' && !Array.isArray(value) ? value : {};
	}
	catch (err) {
		return {};
	}
}

function saveProbeCache(cache) {
	try {
		window.localStorage.setItem(PROBE_CACHE_KEY, JSON.stringify(cache || {}));
	}
	catch (err) {}
}

function startManualProbeAnimation(badge) {
	badge.setAttribute('aria-busy', 'true');
	badge._wanpilotProbeText = badge.textContent;
	badge.textContent = '';
	badge._wanpilotProbeAnimations = [];

	var dots = E('span', {
		'style': 'display:inline-flex;align-items:center;justify-content:center;gap:0.2rem;min-height:1em;',
		'aria-hidden': 'true'
	});
	for (var i = 0; i < 3; i++) {
		var dot = E('span', {
			'style': 'display:inline-block;font-size:0.72rem;line-height:1;'
		}, [ '\u2022' ]);
		dots.appendChild(dot);
		try {
			if (typeof dot.animate === 'function') {
				badge._wanpilotProbeAnimations.push(dot.animate([
					{ transform: 'translateY(0)' },
					{ transform: 'translateY(-0.22rem)' },
					{ transform: 'translateY(0)' }
				], {
					duration: 720,
					delay: i * 120,
					iterations: Infinity,
					easing: 'ease-in-out'
				}));
			}
		}
		catch (err) {}
	}
	badge.appendChild(dots);

	try {
		if (typeof badge.animate === 'function') {
			badge._wanpilotProbeAnimations.push(badge.animate([
				{ transform: 'scale(1)' },
				{ transform: 'scale(0.96)' },
				{ transform: 'scale(1)' }
			], {
				duration: 160,
				iterations: 1,
				easing: 'ease-out'
			}));
		}
	}
	catch (err) {}
}

function stopManualProbeAnimation(badge, keepResult) {
	(badge._wanpilotProbeAnimations || []).forEach(function(animation) {
		animation.cancel();
	});
	if (!keepResult && badge._wanpilotProbeText != null)
		badge.textContent = badge._wanpilotProbeText;
	badge._wanpilotProbeAnimations = null;
	badge._wanpilotProbeText = null;
	badge.removeAttribute('aria-busy');
	badge._wanpilotProbing = false;
}

function makeSwitchButton(item, switchFn) {
	var isSelectable = isTrue(item.default_route) && !isTrue(item.active);
	var label = isTrue(item.active)
		? _('Uplink')
		: (isTrue(item.default_route) ? _('Select') : _('No route'));
	var cls = isTrue(item.active)
		? 'cbi-button cbi-button-small cbi-button-apply'
		: (isSelectable ? 'cbi-button cbi-button-small cbi-button-action'
				: 'cbi-button cbi-button-small cbi-button-neutral');
	var attrs = {
		'type': 'button',
		'class': cls,
		'style': 'width:100%;justify-content:center;',
		'click': function(ev) {
			ev.preventDefault();
			if (!isSelectable)
				return;
			return switchFn(item, ev.currentTarget);
		}
	};
	if (!isSelectable)
		attrs.disabled = 'disabled';
	return E('button', attrs, [ label ]);
}

return baseclass.extend({
	title: _('WANPilot'),

	state: null,
	probeCache: null,
	statusTimer: null,
	probeTimer: null,
	probeRunning: false,
	probeIntervalMs: DEFAULT_PROBE_INTERVAL_MS,
	cardNodes: null,
	badgeRefs: null,
	rootNode: null,
	initialized: false,
	initialStatusRunning: false,

	load: function() {
		if (!this.initialized) {
			this.state = null;
			this.probeCache = loadProbeCache();
			this.cardNodes = {};
			this.badgeRefs = {};
			this.initialized = true;
		}
		return Promise.resolve(null);
	},

	_renderCardContent: function(item) {
		var name = String(item.display_name || item.name || '');
		var subName = (item.name && item.display_name && String(item.name) !== String(item.display_name))
			? String(item.name) : '';
		var con = getConnectionLabel(item);
		var connBadge = E('span', { 'class': con.cls, 'style': 'font-size:0.82rem;line-height:1.6rem;padding:0 0.55rem;' }, [ con.text ]);

		var zoneLine = String(item.zone || '-') + ' / ' + String(item.proto || '-')
			+ '  |  ' + _('Device') + ': ' + String(item.device || '-');
		var netLine = _('IPv4') + ': ' + formatIPList(item.ipv4)
			+ '   ' + _('GW') + ': ' + String(item.gateway || '-');
		var metaLine = _('Metric') + ': ' + String(item.effective_metric || item.configured_metric || '-')
			+ '   ' + _('DNS') + ': ' + formatList(item.dns);
		return {
			style: getCardStyle(item),
			connBadge: connBadge,
			header: name,
			subName: subName,
			zoneLine: zoneLine,
			netLine: netLine,
			metaLine: metaLine,
			isActive: isTrue(item.active),
			equalPriority: isTrue(item.equal_priority)
		};
	},

	_renderCards: function(data) {
		var self = this;
		var cards = [];
		((data && data.interfaces) || []).forEach(function(item) {
			if (isTrue(item.hidden))
				return;
			var meta = self._renderCardContent(item);
			var iface = String(item.name);

			if (!self.probeCache[iface] || typeof self.probeCache[iface] !== 'object' || Array.isArray(self.probeCache[iface]))
				self.probeCache[iface] = { google: null, yandex: null };
			if (!self.badgeRefs[iface])
				self.badgeRefs[iface] = { google: null, yandex: null };

			var makeBadge = function(target, label) {
				var cache = self.probeCache[iface][target];
				var ok = cache && isTrue(cache.ok);
				var cls;
				if (ok)
					cls = 'cbi-button cbi-button-small cbi-button-positive';
				else if (cache)
					cls = 'cbi-button cbi-button-small cbi-button-negative';
				else
					cls = 'cbi-button cbi-button-small cbi-button-neutral';
				var node = E('button', {
					'type': 'button',
					'class': cls,
						'style': 'margin-right:0.35rem;padding:0 0.45rem;line-height:1.6rem;font-size:0.78rem;min-width:5.4rem;white-space:nowrap;justify-content:center;',
					'title': _('Probe %s via %s').format(label, iface),
						'click': function(ev) {
							ev.preventDefault();
							var badge = ev.currentTarget;
							if (badge._wanpilotProbing)
								return;
							badge._wanpilotProbing = true;
							startManualProbeAnimation(badge);
							Promise.resolve(callProbe(iface, target)).then(function(reply) {
								var match = matchProbeResult(reply, target);
								if (match) {
									self._applyProbeResult(iface, target, match);
									stopManualProbeAnimation(badge, true);
									self._refreshStatus();
								}
								else
									stopManualProbeAnimation(badge, false);
							}).catch(function(err) {
								stopManualProbeAnimation(badge, false);
								ui.addNotification(null, E('p', {}, [ String(err) ]), 'danger');
							});
					}
				}, [ formatProbeText(label, cache) ]);
				self.badgeRefs[iface][target] = node;
				return node;
			};

			var probeRow = E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:0.1rem;margin-top:0.4rem;' }, [
				makeBadge('google', 'G'),
				makeBadge('yandex', 'Y')
			]);

			var cardNode = E('div', { 'style': meta.style, 'class': 'wanpilot-interface-card' }, [
				E('div', {}, [
					E('div', { 'style': 'display:flex;justify-content:space-between;align-items:flex-start;gap:0.6rem;' }, [
						E('div', { 'style': 'min-width:0;overflow-wrap:anywhere;' }, [
							E('strong', { 'style': 'font-size:0.96rem;letter-spacing:0.02em;' }, [ meta.header ]),
							meta.subName ? E('div', { 'style': 'font-size:0.72rem;opacity:0.7;margin-top:0.1rem;' }, [ '(' + meta.subName + ')' ]) : ''
						]),
						meta.connBadge
					]),
					E('div', { 'style': 'margin-top:0.55rem;' }, [
						E('div', { 'style': 'font-size:0.78rem;opacity:0.74;' }, [ meta.zoneLine ]),
						E('div', { 'style': 'font-size:0.78rem;opacity:0.74;margin-top:0.1rem;' }, [ meta.netLine ]),
						E('div', { 'style': 'font-size:0.78rem;opacity:0.74;margin-top:0.1rem;' }, [ meta.metaLine ]),
						meta.isActive
							? E('div', { 'style': 'margin-top:0.5rem;' }, [
								E('span', { 'class': 'label label-success', 'style': 'display:inline-block;line-height:1.2rem;padding:0 0.5rem;' }, [ _('ACTIVE UPLINK') ])
							  ])
							: (meta.equalPriority
								? E('div', { 'style': 'margin-top:0.5rem;' }, [
									E('span', { 'class': 'label label-warning', 'style': 'display:inline-block;line-height:1.2rem;padding:0 0.5rem;' }, [ _('SAME PRIORITY') ])
								  ])
								: E('div', { 'style': 'margin-top:0.5rem;min-height:1.2rem;' }, [ '\u00a0' ])
							  )
					]),
					probeRow
				]),
				makeSwitchButton(item, function(selected, button) {
					return self._switchUplink(selected, button);
				})
			]);
			self.cardNodes[iface] = cardNode;
			cards.push(cardNode);
		});
		return cards;
	},

	_applyProbeResult: function(iface, target, result) {
		var badge = this.badgeRefs[iface] && this.badgeRefs[iface][target];
		if (!result)
			return;

		if (!this.probeCache[iface] || typeof this.probeCache[iface] !== 'object' || Array.isArray(this.probeCache[iface]))
			this.probeCache[iface] = { google: null, yandex: null };
		this.probeCache[iface][target] = result;
		saveProbeCache(this.probeCache);
		if (badge) {
			badge.setAttribute('class', isTrue(result.ok)
				? 'cbi-button cbi-button-small cbi-button-positive'
				: 'cbi-button cbi-button-small cbi-button-negative');
			badge.textContent = formatProbeText(target === 'google' ? 'G' : 'Y', result);
		}
	},

	_applyStatusToCard: function(item) {
		var iface = String(item.name);
		var cardNode = this.cardNodes[iface];
		if (!cardNode)
			return;

		var con = getConnectionLabel(item);
		var badge = cardNode.querySelector('.ifacebadge');
		if (badge) {
			badge.setAttribute('class', con.cls);
			badge.textContent = con.text;
		}

		cardNode.setAttribute('style', getCardStyle(item));
	},

	_refreshStatus: function(rebuild) {
		var self = this;
		return Promise.resolve(callStatus()).then(function(data) {
			self.state = data || self.state;
			self.probeIntervalMs = getProbeIntervalMs(self.state && self.state.online_check_interval);
			if (rebuild && data && self.rootNode && document.body.contains(self.rootNode)) {
				dom.content(self.rootNode, self._renderOverviewContent(data));
				return data;
			}
			((data && data.interfaces) || []).forEach(function(item) {
				if (isTrue(item.hidden))
					return;
				self._applyStatusToCard(item);
			});
			return data;
		}).catch(function() {});
	},

	_switchUplink: function(item, button) {
		var self = this;
		var label = String(item.display_name || item.name || '');
		if (button._wanpilotSwitching)
			return Promise.resolve();

		button._wanpilotSwitching = true;
		button.disabled = true;
		ui.showModal(_('Switching uplink'), [
			E('p', { 'class': 'spinning' }, [
				_('Switching to %s. WANPilot is updating route metrics and waiting for OpenWrt to confirm the new default route…').format(label)
			])
		]);

		return Promise.resolve(callSwitch(item.name)).then(function(reply) {
			if (!reply || !isTrue(reply.ok))
				throw new Error(reply && reply.error ? String(reply.error) : _('Switch verification failed'));
			return self._refreshStatus(true);
		}).then(function() {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, [
				_('Current uplink changed to %s.').format(label)
			]), 'info');
		}).catch(function(err) {
			ui.hideModal();
			button._wanpilotSwitching = false;
			button.disabled = false;
			ui.addNotification(null, E('p', {}, [
				_('Could not switch to %s: %s').format(label, String(err))
			]), 'danger');
		});
	},

	_refreshProbes: function() {
		var self = this;
		if (self.probeRunning || !self.state || !isTrue(self.state.online_check_enabled)
				|| (self.state.service_running != null && !isTrue(self.state.service_running)))
			return Promise.resolve();

		var ifaces = (self.state.interfaces || []).filter(function(item) {
			return self.probeCache[String(item.name)] && !isTrue(item.hidden) && isTrue(item.default_route)
				&& (isTrue(item.up) || isTrue(item.available));
		}).map(function(item) {
			return String(item.name);
		});
		if (ifaces.length === 0)
			return Promise.resolve();

		self.probeRunning = true;
		return Promise.all(ifaces.map(function(iface) {
			return Promise.resolve(callProbe(iface, 'both')).then(function(reply) {
				if (!reply || !Array.isArray(reply.results))
					return;
				reply.results.forEach(function(r) {
					if (!r || !r.name)
						return;
					var target = r.name;
					if (target !== 'google' && target !== 'yandex')
						return;
					self._applyProbeResult(iface, target, r);
				});
			}).catch(function() {});
		})).then(function(result) {
			return self._refreshStatus().then(function() {
				self.probeRunning = false;
				return result;
			});
		}, function() {
			self.probeRunning = false;
		});
	},

	_startTimers: function() {
		var self = this;
		self._stopTimers();
		self.statusTimer = window.setInterval(function() {
			if (!self.rootNode || !document.body.contains(self.rootNode)) {
				self._stopTimers();
				return;
			}
			self._refreshStatus();
		}, STATUS_INTERVAL_MS);

		var scheduleProbe = function(delay) {
			self.probeTimer = window.setTimeout(function() {
				if (!self.rootNode || !document.body.contains(self.rootNode)) {
					self._stopTimers();
					return;
				}
				self._refreshProbes().then(function() {
					if (self.rootNode && document.body.contains(self.rootNode))
						scheduleProbe(self.probeIntervalMs);
					else
						self._stopTimers();
				});
			}, delay);
		};
		// Fill the badges without delaying page rendering. Later cycles wait for
		// the configured interval after the previous cycle has completed.
		scheduleProbe(0);
	},

	_stopTimers: function() {
		if (this.statusTimer) {
			window.clearInterval(this.statusTimer);
			this.statusTimer = null;
		}
		if (this.probeTimer) {
			window.clearTimeout(this.probeTimer);
			this.probeTimer = null;
		}
	},

	_renderOverviewContent: function(data) {
		this.state = data || this.state || { ok: true, interfaces: [] };
		this.probeIntervalMs = getProbeIntervalMs(this.state.online_check_interval);
		this.cardNodes = {};
		this.badgeRefs = {};
		var activeLabel = _('No active uplink');
		var note = _('Connected means the uplink is established. Online means WANPilot could reach Google or Yandex through that uplink. Click G or Y to re-probe immediately.');

		if (this.state.active_state === 'active' && this.state.active_interface)
			activeLabel = _('Current uplink: %s').format(this.state.active_interface);
		else if (this.state.active_state === 'multiple')
			activeLabel = _('Several uplinks currently have the same priority');

		if (this.state && this.state.service_running != null && !isTrue(this.state.service_running))
			note = _('WANPilot service is stopped. Run "wanpilot start" or "wanpilot restart" to resume checks.');
		else if (this.state && !isTrue(this.state.online_check_enabled))
			note = _('Internet check is disabled.');
		else if (this.state && !isTrue(this.state.online_check_supported))
			note = _('Internet check is unavailable. Install the "curl" package to enable it.');

		var cards = this._renderCards(this.state);

		return [
			E('div', {
				'style': 'display:flex;flex-wrap:wrap;gap:0.5rem 1rem;align-items:baseline;margin-bottom:0.9rem;'
			}, [
				E('strong', {}, [ activeLabel ]),
				E('span', { 'style': 'font-size:0.8rem;opacity:0.72;' }, [ note ])
			]),
			E('div', {
				'style': 'display:flex;flex-wrap:wrap;gap:0.9rem;align-items:stretch;'
			}, cards)
		];
	},

	_loadInitialStatus: function() {
		var self = this;
		if (self.initialStatusRunning)
			return Promise.resolve();

		self.initialStatusRunning = true;
		return Promise.resolve(callStatus()).then(function(data) {
			if (!self.rootNode || !document.body.contains(self.rootNode))
				return;
			dom.content(self.rootNode, self._renderOverviewContent(data));
			self._startTimers();
		}).catch(function(err) {
			if (self.rootNode && document.body.contains(self.rootNode))
				dom.content(self.rootNode, [ E('span', { 'class': 'error' }, [ _('Unable to load WANPilot: %s').format(String(err)) ]) ]);
		}).then(function() {
			self.initialStatusRunning = false;
		});
	},

	render: function() {
		var self = this;
		if (!this.rootNode) {
			this.rootNode = E('div', { 'class': 'cbi-section wanpilot-overview' }, [
				E('span', { 'class': 'spinning' }, [ _('Loading WANPilot…') ])
			]);
		}

		// LuCI calls load()/render() again while refreshing Overview. Keep the
		// same node so cards and their last completed probe results are preserved.
		window.setTimeout(function() {
			if (!self.rootNode || !document.body.contains(self.rootNode))
				return;
			if (!self.state)
				self._loadInitialStatus();
			else if (!self.statusTimer && !self.probeTimer) {
				self._refreshStatus();
				self._startTimers();
			}
		}, 0);
		return this.rootNode;
	},

	handleSave: function() { return Promise.resolve(); },
	handleSaveApply: function() { return Promise.resolve(); },
	handleReset: function() { return Promise.resolve(); }
});
