// WANPilot LuCI runtime status view with active uplink summary and one-click switching.
'use strict';
'require view';
'require rpc';
'require poll';
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

const callConfig = rpc.declare({
        object: 'wanpilot',
        method: 'config',
        params: [ 'action', 'zone', 'interface', 'display_name', 'hidden', 'order' ]
});

function isTrue(value) {
        return value === true || value === 1 || value === '1' || value === 'true';
}

function getConnectionText(item) {
        if (isTrue(item.online))
                return _('Online');

        if (isTrue(item.up) || isTrue(item.available))
                return _('Connected');

        return _('Offline');
}

function getRoleText(item) {
        if (isTrue(item.hidden))
                return _('Hidden');

        if (isTrue(item.active))
                return _('Uplink');

        if (isTrue(item.equal_priority))
                return _('Same Priority');

        if (isTrue(item.default_route))
                return _('Available');

        return _('Not Ready');
}

function getSelectLabel(item) {
        if (isTrue(item.hidden))
                return _('Hidden');

        if (isTrue(item.active))
                return _('Uplink');

        if (!isTrue(item.default_route))
                return _('No Route');

        return _('Select');
}

function renderSummary(data) {
        let summary = _('No active uplink');
	let note = _('Connected means the uplink itself is up. Online means WANPilot can reach a test target through that uplink.');

        if (data.active_state === 'active' && data.active_interface)
                summary = _('Current uplink: %s').format(data.active_interface);
        else if (data.active_state === 'multiple')
                summary = _('Several uplinks currently have the same priority');

	if (data.service_running != null && !isTrue(data.service_running))
		note = _('WANPilot service is stopped. Run "wanpilot start" or "wanpilot restart" to resume checks.');
        else if (!isTrue(data.online_check_enabled))
                note = _('Internet check is disabled. Connected does not verify real internet access.');
        else if (!isTrue(data.online_check_supported))
		note = _('Internet check is unavailable because curl is not installed.');

        return E('div', { 'class': 'cbi-section' }, [
                E('h3', {}, [ _('WANPilot Summary') ]),
                E('p', {}, [ summary ]),
                E('p', { 'class': 'small' }, [ note ]),
                E('p', { 'class': 'small' }, [ _('Hidden interfaces can be restored on the Configuration page.') ])
        ]);
}

function renderTable(data, refreshFn) {
        const rows = E('table', { 'class': 'table' }, [
                E('tr', { 'class': 'tr' }, [
                        E('th', { 'class': 'th' }, [ _('Interface') ]),
                        E('th', { 'class': 'th' }, [ _('Connection') ]),
                        E('th', { 'class': 'th' }, [ _('Role') ]),
                        E('th', { 'class': 'th' }, [ _('Actions') ])
                ])
        ]);

        (data.interfaces || []).forEach(function(item) {
                const isHidden = isTrue(item.hidden);
                const hideAttrs = {
                        'type': 'button',
                        'class': 'cbi-button cbi-button-neutral',
                        'style': 'margin-right:0.5rem;',
                        'click': function(ev) {
                                ev.preventDefault();
                                return callConfig('set-hidden', null, item.name, null, isHidden ? 0 : 1, null).then(function(reply) {
                                        if (reply && reply.ok)
                                                ui.addNotification(null, E('p', {}, [
                                                        isHidden ?
                                                                _('Interface %s is visible on the dashboard again.').format(item.display_name || item.name) :
                                                                _('Interface %s was hidden from the dashboard.').format(item.display_name || item.name)
                                                ]), 'info');
                                        else
                                                ui.addNotification(null, E('p', {}, [
                                                        isHidden ?
                                                                _('Unable to restore %s.').format(item.display_name || item.name) :
                                                                _('Unable to hide %s.').format(item.display_name || item.name)
                                                ]), 'danger');
                                        return refreshFn();
                                }).catch(function(err) {
                                        ui.addNotification(null, E('p', {}, [ String(err) ]), 'danger');
                                });
                        }
                };
                const selectAttrs = {
                        'type': 'button',
                        'class': 'cbi-button cbi-button-action',
                        'click': function(ev) {
                                ev.preventDefault();
                                return callSwitch(item.name).then(function(reply) {
                                        if (reply && reply.ok)
                                                ui.addNotification(null, E('p', {}, [ _('Current uplink changed to %s.').format(item.display_name || item.name) ]), 'info');
                                        else
                                                ui.addNotification(null, E('p', {}, [ _('Could not switch to %s.').format(item.display_name || item.name) ]), 'danger');
                                        return refreshFn();
                                }).catch(function(err) {
                                        ui.addNotification(null, E('p', {}, [ String(err) ]), 'danger');
                                });
                        }
                };
                const detail = [ item.name ];
                if (item.proto)
                        detail.push(item.proto);
                if (item.device)
                        detail.push(item.device);

                if (isTrue(item.active))
                        hideAttrs.disabled = 'disabled';

                if (!isTrue(item.default_route) || isTrue(item.active) || isHidden)
                        selectAttrs.disabled = 'disabled';

                rows.appendChild(E('tr', {
                        'class': 'tr',
                        'style': isHidden ? 'opacity:0.55;' : ''
                }, [
                        E('td', { 'class': 'td' }, [
                                E('strong', {}, [ item.display_name || item.name ]),
                                E('div', { 'class': 'small' }, [ detail.join(' | ') ])
                        ]),
                        E('td', { 'class': 'td' }, [ getConnectionText(item) ]),
                        E('td', { 'class': 'td' }, [ getRoleText(item) ]),
                        E('td', { 'class': 'td' },
                                (function() {
                                        var cells = [];
                                        cells.push(E('button', hideAttrs, [ isHidden ? _('Show') : _('Hide') ]));
                                        cells.push(E('button', selectAttrs, [ getSelectLabel(item) ]));
                                        return cells;
                                })()
                        )
                ]));
        });

        return E('div', { 'class': 'cbi-section' }, [
                E('h3', {}, [ _('Candidates') ]),
                rows
        ]);
}

return view.extend({
        load: function() {
                return Promise.resolve(callStatus());
        },

        render: function(data) {
                const root = E('div', { 'class': 'wanpilot-status-view' });

                function refresh() {
                        return Promise.resolve(callStatus()).then(function(nextData) {
                                dom.content(root, [
                                        renderSummary(nextData),
                                        renderTable(nextData, refresh)
                                ]);
                        });
                }

                poll.add(function() {
                        return refresh();
                }, 5);

                dom.content(root, [
                        renderSummary(data),
                        renderTable(data, refresh)
                ]);

                return root;
        },

        handleSave: null,
        handleSaveApply: null,
        handleReset: null
});
