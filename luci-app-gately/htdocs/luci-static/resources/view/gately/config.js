'use strict';
'require view';
'require gately/common';

var C   = gately_common;
var KEYS = [
    'port', 'delay', 'configdir', 'binpath',
    'arch', 'release_type',
    'respawn_threshold', 'respawn_timeout', 'respawn_retry',
    'auto_update', 'update_interval'
];

var api = {
    settings:      C.rpc('get_settings'),
    arch:          C.rpc('get_arch'),
    save:          C.rpc('save_settings', KEYS),
    reset:         C.rpc('reset_password'),
    listBackups:   C.rpc('list_backups'),
    restoreBackup: C.rpc('restore_backup', ['filename'])
};

return view.extend({
    load: function() {
        return Promise.all([
            L.resolveDefault(api.settings(), {}),
            L.resolveDefault(api.arch(),     {})
        ]);
    },

    handleSave:      function() { return this._save(); },
    handleSaveApply: null,
    handleReset:     function() { location.reload(); },

    _save: function() {
        return api.save.apply(null, KEYS.map(C.fval)).then(function(res) {
            var ok = res && res.result === 'ok';
            C.showToast({
                ok:      ok,
                title:   ok ? _('Saved') : _('Save Failed'),
                msg:     ok ? _('Settings saved successfully.')
                            : _('Save failed'),
                timeout: ok ? 2000 : 0
            });
        });
    },

    render: function(data) {
        var cfg  = data[0] || {};
        var arch = (data[1] || {}).arch || _('Unknown');

        var autoUpdate = cfg.auto_update === '1';

        var restoreBtn = E('button', {
            type: 'button',
            id: '_f_restore',
            class: 'gately-btn gately-btn-primary',
            click: function() {
                restoreBtn.disabled = true;
                L.resolveDefault(api.listBackups(), {}).then(function(res) {
                    restoreBtn.disabled = false;
                    var files = (res && res.files) ? res.files : [];

                    if (!files.length) {
                        C.showToast({
                            ok: false,
                            title: _('No Backups'),
                            msg: _('No backup files found.'),
                            timeout: 2500
                        });
                        return;
                    }

                    var overlay;
                    function closePanel() {
                        if (overlay && overlay.parentNode)
                            overlay.parentNode.removeChild(overlay);
                    }

                    function buildFileBtn(f) {
                        return E('button', {
                            type: 'button',
                            class: 'gately-file-btn',
                            title: f.name,
                            click: function() {
                                closePanel();
                                if (!window.confirm(
                                    _('Restore backup: %s ?').format(f.name)
                                )) return;
                                L.resolveDefault(
                                    api.restoreBackup(f.name), {}
                                ).then(function(r) {
                                    var ok = r && r.result === 'ok';
                                    C.showToast({
                                        ok:      ok,
                                        title:   ok ? _('Restored') : _('Failed'),
                                        msg:     ok
                                            ? _('Backup restored successfully.')
                                            : _('Restore failed'),
                                        timeout: ok ? 2500 : 0
                                    });
                                });
                            }
                        }, f.name);
                    }

                    var card = E('div', { class: 'gately-panel' }, [
                        E('h3', { class: 'gately-panel-title' },
                            [C.icon('folder', 16), E('span', {}, _('Select Backup to Restore'))]),
                        E('p', { class: 'gately-panel-desc' }, _('Click a file to restore it:')),
                        E('div', { class: 'gately-file-list' }, files.map(buildFileBtn)),
                        E('div', { class: 'gately-panel-foot' }, [
                            E('button', {
                                type: 'button',
                                class: 'gately-btn gately-btn-danger',
                                click: closePanel
                            }, _('Cancel'))
                        ])
                    ]);

                    overlay = E('div', { class: 'gately-panel-overlay' }, [card]);
                    overlay.addEventListener('click', function(ev) {
                        if (ev.target === overlay) closePanel();
                    });
                    card.addEventListener('click', function(ev) {
                        ev.stopPropagation();
                    });
                    document.body.appendChild(overlay);
                });
            }
        }, [C.icon('folder', 14), E('span', {}, _('Restore Backup'))]);

        var resetBtn = E('button', {
            type: 'button',
            id: '_f_reset',
            class: 'gately-btn gately-btn-danger',
            click: function() {
                if (!window.confirm(
                    _('Reset admin password to default (gately.cn)? Service will restart.'))) return;
                L.resolveDefault(api.reset(), {}).then(function(res) {
                    C.showToast({
                        ok:      !!(res && res.result),
                        title:   (res && res.result)
                                     ? _('Reset Success') : _('Reset Failed'),
                        msg:     (res && res.result)
                                     ? _('Credentials reset to default, service restarting…')
                                     : _('Reset failed, please check the log.'),
                        timeout: (res && res.result) ? 2500 : 0
                    });
                });
            }
        }, [C.icon('trash', 14), E('span', {}, _('Reset password'))]);

        var descThreshold = E('span', {}, '');
        var descTimeout   = E('span', {}, '');
        var descRetry     = E('span', {}, '');

        function fmtThreshold(v) {
            var n = parseInt(v) || 0;
            return n === 0
                ? _('Uptime > 0s always resets the retry counter')
                : _('Uptime exceeds %ss, retry counter resets').format(n);
        }
        function fmtTimeout(v) {
            return _('Wait %ss before restarting after a crash').format(parseInt(v) || 0);
        }
        function fmtRetry(v) {
            var n = parseInt(v) || 0;
            return n === 0
                ? _('Unlimited retries')
                : _('Stop after %s restart(s), 0 No limits').format(n);
        }

        descThreshold.textContent = fmtThreshold(cfg.respawn_threshold || '3600');
        descTimeout.textContent   = fmtTimeout(cfg.respawn_timeout     || '30');
        descRetry.textContent     = fmtRetry(cfg.respawn_retry         || '5');

        var mapEl = E('div', { class: 'cbi-map gately-page' }, [
            E('h2', {}, _('Gately — Settings')),

            C.buildCard(_('Basic Service'), [
                C.buildFormRow('text', 'port', _('Web UI Port'),
                    cfg.port || '16680',
                    _('Used for the page shortcut. Change the actual port in Gately settings.'),
                    { style: 'width:100px;' }),
                C.buildFormRow('number', 'delay', _('Delayed Start (s)'),
                    cfg.delay || '60',
                    _('Delay before starting after boot (only when uptime < 120s)'),
                    { style: 'width:80px;', min: '0' }),
                C.buildFormRow('custom', 'restore', _('Restore Backup'),
                    null,
                    _('Restore Gately config from a previous backup'),
                    restoreBtn),
                C.buildFormRow('custom', 'reset', _('Reset Credentials'),
                    null,
                    _('Reset admin password back to the default gately.cn'),
                    resetBtn)
            ], { icon: 'gear' }),

            C.buildGrid(280, [
                C.buildCard(_('Path & Architecture'), [
                    C.buildFormRow('text', 'configdir', _('Data Directory'),
                        cfg.configdir || '/etc/gately',
                        _('Gately runtime data directory (passed via -c)')),
                    C.buildFormRow('text', 'binpath', _('Binary Path'),
                        cfg.binpath || '/usr/bin/gately',
                        _('Full path to the Gately executable')),
                    C.buildFormRow('text', 'arch', _('Architecture'),
                        cfg.arch || 'auto',
                        E('span', {}, [
                            _('Detected:'), E('strong', {}, arch), E('br'),
                            _('Leave "auto" to detect automatically')
                        ]),
                        { style: 'width:120px;' })
                ], { icon: 'folder' }),
                C.buildCard(_('Download & Update'), [
                    C.buildFormRow('select', 'release_type', _('Release Channel'),
                        cfg.release_type || 'stable',
                        _('Include pre-release versions (rc) when checking'), [
                            { v: 'stable',     l: _('Stable') },
                            { v: 'prerelease', l: _('Include pre-release') }
                        ])
                ], { icon: 'download' })
            ]),

            C.buildGrid(280, [
                C.buildCard(_('Respawn Policy'), [
                    C.buildFormRow('number', 'respawn_threshold', _('Crash Threshold (s)'),
                        cfg.respawn_threshold || '3600',
                        descThreshold,
                        { style: 'width:80px;', min: '0' }),
                    C.buildFormRow('number', 'respawn_timeout', _('Respawn Delay (s)'),
                        cfg.respawn_timeout || '30',
                        descTimeout,
                        { style: 'width:80px;', min: '0' }),
                    C.buildFormRow('number', 'respawn_retry', _('Max Retries'),
                        cfg.respawn_retry || '5',
                        descRetry,
                        { style: 'width:80px;', min: '0' })
                ], { icon: 'refresh' }),
                C.buildCard(_('Auto Update'), [
                    C.buildFormRow('toggle', 'auto_update', _('Enable Auto Update'),
                        cfg.auto_update || '0',
                        _('Periodically check and install the latest version')),
                    C.buildFormRow('number', 'update_interval', _('Check Interval (days)'),
                        cfg.update_interval || '7',
                        _('Range: 1 – 365 days'),
                        { style: 'width:80px;', min: '1', max: '365' })
                ], { icon: 'clock' })
            ])
        ]);

        C.initThemeButton();

        var autoEl = mapEl.querySelector('#_f_auto_update');
        if (autoEl) {
            autoEl.addEventListener('change', function() {
                C.rowVis('update_interval', this.checked);
            });
        }

        window.setTimeout(function() {
            C.rowVis('update_interval', autoUpdate);

            var elThreshold = mapEl.querySelector('#_f_respawn_threshold');
            var elTimeout   = mapEl.querySelector('#_f_respawn_timeout');
            var elRetry     = mapEl.querySelector('#_f_respawn_retry');

            if (elThreshold) elThreshold.addEventListener('input', function() {
                descThreshold.textContent = fmtThreshold(this.value);
            });
            if (elTimeout) elTimeout.addEventListener('input', function() {
                descTimeout.textContent = fmtTimeout(this.value);
            });
            if (elRetry) elRetry.addEventListener('input', function() {
                descRetry.textContent = fmtRetry(this.value);
            });
        }, 0);

        return mapEl;
    }
});
