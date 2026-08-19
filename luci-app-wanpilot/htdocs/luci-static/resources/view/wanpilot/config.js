// WANPilot LuCI configuration view for discovery settings and interface metadata.
'use strict';
'require view';
'require form';

return view.extend({
        render: function() {
                let m, s, o;

                m = new form.Map('wanpilot', _('WANPilot'),
                        _('Configure discovery, manual uplinks and UI metadata. Active state is always derived from current routing state.'));

                s = m.section(form.NamedSection, 'main', 'core', _('Core Settings'));
                s.anonymous = true;

                o = s.option(form.Value, 'discovery_zone', _('Discovery firewall zone'),
                        _('Auto-discover uplink candidates from this firewall zone.'));
                o.placeholder = 'wan';
                o.rmempty = false;

                o = s.option(form.Value, 'preferred_metric', _('Preferred metric'),
                        _('Metric assigned to the selected uplink. Non-selected uplinks get deterministic higher metrics.'));
                o.placeholder = '10';
                o.datatype = 'uinteger';
                o.rmempty = false;

                o = s.option(form.Flag, 'online_check_enabled', _('Internet check'),
			_('Probe each uplink through Google and Yandex and report connectivity. Manual click on G/Y re-probes immediately.'));
                o.default = '1';
                o.rmempty = false;

		o = s.option(form.Value, 'online_check_interval', _('Check interval'),
			_('Seconds between completed automatic probe cycles. A new cycle never starts while the previous one is still running.'));
		o.placeholder = '10';
		o.datatype = 'uinteger';
		o.rmempty = false;

                o = s.option(form.Value, 'online_check_timeout', _('Check timeout'),
			_('Maximum seconds for each Google or Yandex request before that target is treated as failed.'));
                o.placeholder = '4';
                o.datatype = 'uinteger';
                o.rmempty = false;

                s = m.section(form.TypedSection, 'manual', _('Manual Uplinks'),
                        _('Add arbitrary OpenWrt interfaces even when they are outside the discovery zone.'));
                s.anonymous = true;
                s.addremove = true;

                o = s.option(form.Value, 'interface', _('Interface'));
                o.rmempty = false;

                o = s.option(form.Value, 'display_name', _('Display name'));
                o.rmempty = true;

                o = s.option(form.Flag, 'hidden', _('Hidden'));
                o.default = '0';
                o.rmempty = false;

                o = s.option(form.Value, 'order', _('Order'));
                o.datatype = 'uinteger';
                o.placeholder = '500';
                o.rmempty = true;

                s = m.section(form.TypedSection, 'override', _('Auto-discovered Overrides'),
                        _('Rename, hide or re-order interfaces discovered from the firewall zone.'));
                s.anonymous = true;
                s.addremove = true;

                o = s.option(form.Value, 'interface', _('Interface'));
                o.rmempty = false;

                o = s.option(form.Value, 'display_name', _('Display name'));
                o.rmempty = true;

                o = s.option(form.Flag, 'hidden', _('Hidden'));
                o.default = '0';
                o.rmempty = false;

                o = s.option(form.Value, 'order', _('Order'));
                o.datatype = 'uinteger';
                o.placeholder = '100';
                o.rmempty = true;

                return m.render();
        }
});
