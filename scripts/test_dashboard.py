#!/usr/bin/env python3
"""Shared dashboard regressions. All credentials and session writes are fixtures."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent


def module():
    spec = importlib.util.spec_from_file_location('ai_usage', ROOT / 'scripts/ai-usage.py')
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class Fixture:
    def __init__(self, directory):
        self.m = module()
        self.directory = Path(directory)
        self.m.home = lambda: str(self.directory)
        self.keychain = {}
        self.m.read_macos_keychain = lambda service, account: self.keychain.get((service, account))
        def write(service, account, value):
            self.keychain[(service, account)] = value
            return True
        self.m.write_macos_keychain = write
        self.m.delete_macos_keychain = lambda service, account: self.keychain.pop((service, account), None) is not False
        self.m.cursor_keychain_token = lambda: self.keychain.get(('cursor-access-token', 'cursor-user'))
        self.m.claude_api_key = lambda: None
        self.m.refresh_codex_bundle = lambda bundle: (bundle, 'ok')
        self.m.external_codex_running = lambda: False
        self.m.restart_provider_sessions = lambda provider: ''
        self.m.run_herdr = lambda args: {}
        self.m.http_json = lambda *args, **kwargs: (_ for _ in ()).throw(AssertionError('unexpected network access'))
        self.m.fetch_provider = lambda provider: dict(self.m.empty_provider(provider, 'ok'), accountLabel=provider + '@fixture.invalid')
        def refresh(*args, **kwargs):
            snapshot = {'fetchedAt': self.m.iso(self.m.now()), 'providers': [self.m.fetch_provider(p) for p in self.m.ORDER]}
            self.m.save_json(self.m.snapshot_path(), snapshot)
            return snapshot
        self.m.refresh = refresh
        path = self.m.cursor_db_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with sqlite3.connect(path) as conn:
            conn.execute('CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)')
            conn.executemany('INSERT INTO ItemTable VALUES (?, ?)', [
                ('cursorAuth/accessToken', 'fixture-cursor-token'),
                ('cursorAuth/refreshToken', 'fixture-cursor-refresh'),
                ('cursorAuth/cachedEmail', 'cursor@fixture.invalid'),
            ])
        self.m.save_json_mkdir = lambda path, value: (os.makedirs(os.path.dirname(path), exist_ok=True), self.m.save_json(path, value))
        self.m.save_json_mkdir(self.m.codex_auth_path(), {'auth_mode': 'chatgpt', 'tokens': {
            'access_token': 'fixture-codex-token', 'refresh_token': 'fixture-codex-refresh',
            'id_token': 'fixture-codex-id-token', 'account_id': 'fixture-codex-id',
        }})
        self.m.save_json_mkdir(self.m.claude_credentials_path(), {
            'claudeAiOauth': {'accessToken': 'fixture-claude-token', 'refreshToken': 'fixture-claude-refresh'},
            'unrelated': 'keep',
        })


class DashboardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.environment = patch.dict(os.environ, {'HOME': self.temp.name, 'PATH': os.environ['PATH'], 'USER': 'fixture'}, clear=True)
        self.environment.start()
        self.platform = patch.object(sys, 'platform', 'darwin')
        self.platform.start()
        self.f = Fixture(self.temp.name)
        self.m = self.f.m

    def tearDown(self):
        self.platform.stop()
        self.environment.stop()
        self.temp.cleanup()

    def test_navigation_without_accounts_and_all_buttons(self):
        for provider in self.m.ORDER:
            for kind in self.m.ACTION_KINDS:
                selected = (kind, provider)
                for direction in ('up', 'down', 'left', 'right'):
                    target = self.m.move_dashboard_selection(selected, direction, [], set())
                    self.assertIn(target, [item['key'] for item in self.m.menu_items([], set())])
                frame, selected = self.m.render_dashboard(None, [], set(self.m.ORDER), selected, None, False, 96, 40, set())
                self.assertIn('▸', frame)
        self.assertEqual(self.m.move_dashboard_selection(('toggle', 'cursor'), 'down', [], set()), ('toggle', 'chatgpt'))
        self.assertEqual(self.m.move_dashboard_selection(('toggle', 'cursor'), 'right', [], set()), ('save', 'cursor'))

    def test_save_apply_logout_and_delete_for_every_provider(self):
        for provider in self.m.ORDER:
            with self.subTest(provider=provider):
                self.assertIn('저장했습니다', self.m.capture(provider))
                account = next(a for a in self.m.load_accounts() if a['provider'] == provider)
                snapshot, message = self.m.clear_live_session(provider)
                self.assertIsNotNone(snapshot, message)
                self.assertIsNone(self.m.live_identity(provider))
                snapshot, message = self.m.activate_account(account['id'])
                self.assertIsNotNone(snapshot, message)
                self.assertIsNotNone(self.m.live_identity(provider))
                self.assertTrue(self.m.active_account(provider)['active'])
                self.assertIn('저장했습니다', self.m.capture(provider))
                self.assertEqual(len([a for a in self.m.load_accounts() if a['provider'] == provider]), 1)
                snapshot, message = self.m.delete_account(account['id'])
                self.assertIsNotNone(snapshot, message)
                self.assertIsNone(self.m.active_account(provider))

    def test_cursor_cli_without_editor_database_can_switch_and_logout(self):
        os.remove(self.m.cursor_db_path())
        self.assertTrue(self.m.write_cursor_session('cli-token', 'cli-refresh', 'cli@fixture.invalid')[0])
        self.assertEqual(self.m.read_cursor_session()['accessToken'], 'cli-token')
        self.assertIn('저장했습니다', self.m.capture('cursor'))
        account = self.m.load_accounts()[0]
        self.assertTrue(self.m.clear_cursor_session()[0])
        self.assertIsNone(self.m.read_cursor_session())
        provider, message = self.m.activate_account(account['id'])
        self.assertIsNotNone(provider, message)
        self.assertEqual(self.m.read_cursor_session()['email'], 'cli@fixture.invalid')

    def test_visibility_can_hide_all_and_show_again(self):
        for provider in self.m.ORDER:
            self.assertFalse(self.m.toggle_visible(provider))
        self.assertEqual(self.m.load_visible(), [])
        self.assertEqual(self.m.status_line({'providers': []}), '')
        self.assertEqual(self.m.statusbar_frame({'providers': []}), '')
        self.assertTrue(self.m.toggle_visible('chatgpt'))
        self.assertEqual(self.m.load_visible(), ['chatgpt'])

    def test_cursor_editor_and_cli_credentials_stay_in_sync(self):
        self.assertTrue(self.m.write_cursor_cli_session('old-cli-token', 'old-refresh', 'old@fixture.invalid')[0])
        self.assertTrue(self.m.write_cursor_session('new-token', None, 'new@fixture.invalid')[0])
        self.assertEqual(self.m.read_cursor_session()['accessToken'], 'new-token')
        self.assertEqual(self.m.read_cursor_cli_session()['accessToken'], 'new-token')
        self.assertIsNone(self.m.read_cursor_session()['refreshToken'])
        self.assertTrue(self.m.clear_cursor_session()[0])
        self.assertIsNone(self.m.read_cursor_session())

    def test_mac_paths_and_swift_data_migration_are_preserved(self):
        self.assertEqual(self.m.data_dir(), str(self.f.directory / 'Library/Application Support/AIUsage'))
        self.assertIn('Library/Application Support/Cursor/', self.m.cursor_db_path())
        original = {'accounts': [{'id': 'swift-id', 'provider': 'chatgpt', 'displayName': 'saved', 'isActive': True}]}
        self.m.save_json(self.m.accounts_path(), original)
        self.m.save_json(os.path.join(self.m.data_dir(), 'credentials.json'), {'credentials': {'swift-id': {'accessToken': 'fixture-secret', 'accountID': 'id'}}})
        preference = self.f.directory / 'Library/Preferences/app.aiusage.AIUsage.plist'
        preference.parent.mkdir(parents=True)
        preference.write_bytes(plistlib.dumps({'visibleProviderIDs': []}))
        self.m.migrate_macos_data()
        self.m.migrate_macos_data()
        account = self.m.load_accounts()[0]
        self.assertTrue(account['active'])
        self.assertEqual(account['oauthToken'], 'fixture-secret')
        self.assertEqual(self.m.load_json(self.m.accounts_path() + '.swift-backup', None), original)
        self.assertEqual(self.m.load_visible(), [])
        self.assertEqual(os.stat(self.m.accounts_path()).st_mode & 0o777, 0o600)

    def test_linux_and_windows_paths_remain_separate(self):
        with patch.object(sys, 'platform', 'linux'), patch.dict(os.environ, {'XDG_DATA_HOME': str(self.f.directory / 'data'), 'XDG_CONFIG_HOME': str(self.f.directory / 'config')}):
            self.assertEqual(self.m.data_dir(), str(self.f.directory / 'data/AIUsage'))
            self.assertIn('/config/Cursor/', self.m.cursor_db_path())
        with patch.object(sys, 'platform', 'win32'), patch.dict(os.environ, {'APPDATA': str(self.f.directory / 'appdata')}):
            self.assertEqual(self.m.data_dir(), str(self.f.directory / 'appdata/AIUsage'))
            self.assertIn('/appdata/Cursor/', self.m.cursor_db_path())

    def test_claude_keychain_precedence_and_failure(self):
        key = (self.m.claude_keychain_service(), self.m.claude_keychain_account())
        self.f.keychain[key] = json.dumps({'claudeAiOauth': {'accessToken': 'keychain-token'}, 'unrelated': 'keep'})
        self.assertEqual(self.m.read_claude_token(), 'keychain-token')
        ok, message = self.m.write_claude_oauth({'accessToken': 'new-token', 'refreshToken': 'new-refresh'})
        self.assertTrue(ok, message)
        self.assertEqual(self.m.read_claude_token(), 'new-token')
        self.assertEqual(json.loads(self.f.keychain[key])['unrelated'], 'keep')
        ok, message = self.m.clear_claude_session()
        self.assertTrue(ok, message)
        self.assertIsNone(self.m.read_claude_token())
        self.assertEqual(json.loads(self.f.keychain[key])['unrelated'], 'keep')
        self.m.read_macos_keychain = lambda *args: self.m.READ_FAILED
        self.m.CLAUDE_CREDENTIAL_CACHE.clear()
        self.assertIs(self.m.read_claude_token(), self.m.READ_FAILED)
        self.assertFalse(self.m.write_claude_oauth({'accessToken': 'no-overwrite'})[0])

    def test_keychain_commands_do_not_put_secrets_in_process_arguments(self):
        m = module()
        with patch.object(m.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '', '')) as run:
            self.assertTrue(m.write_macos_keychain('Claude Code-credentials', 'fixture', 'fixture-secret'))
            self.assertNotIn('fixture-secret', repr(run.call_args.args))
            self.assertIn('fixture-secret'.encode().hex(), run.call_args.kwargs['input'])
        with patch.dict(os.environ, {'CLAUDE_CONFIG_DIR': str(self.f.directory / 'work')}):
            self.assertNotEqual(m.claude_keychain_service(), 'Claude Code-credentials')

    @unittest.skipUnless(os.name != 'nt', 'PTY tests need a POSIX host')
    def test_real_pty_dashboard_actions_and_terminal_restoration(self):
        import fcntl
        import pty
        import select
        import struct
        import termios
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 96, 0, 0))
        before = termios.tcgetattr(slave)
        child_dir = self.f.directory / 'child'
        child_dir.mkdir()
        proc = subprocess.Popen([sys.executable, __file__, '--pty-child', str(child_dir)], stdin=slave, stdout=slave, stderr=slave)
        output = bytearray()
        def pump():
            if select.select([master], [], [], .05)[0]:
                output.extend(os.read(master, 65536))
        def wait_for(predicate):
            deadline = time.monotonic() + 8
            while not predicate():
                if time.monotonic() > deadline or proc.poll() is not None:
                    self.fail('PTY dashboard did not complete the expected action')
                pump()
        def events():
            path = child_dir / 'events.jsonl'
            return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        def send(keys):
            os.write(master, keys)
        def event(name):
            wait_for(lambda: any(row[0] == name for row in events()))
        try:
            wait_for(lambda: b'AI USAGE' in output)
            # Empty provider cards are navigable before any account is saved.
            send(b'\x1b[B\x1b[A\x1b[C\r')
            event('capture')
            send(b'\x1b[C\x1b[C\r\x1b[B\r')
            event('activate_account')
            send(b'd\r')  # The default confirmation cancels deletion.
            wait_for(lambda: '세션 제거를 취소했습니다'.encode() in output)
            self.assertFalse(any(row[0] == 'delete_account' for row in events()))
            send(b'd\x1b[A\r')
            event('delete_account')
            send(b'\x1b[C\x1b[C\r')
            wait_for(lambda: '현재 세션 파일 제거'.encode() in output)
            send(b'\x1b[A\r')
            event('clear_live_session')
            send(b'\x1b[D\x1b[D\r')
            event('toggle_visible')
            send(b'rq')
            wait_for(lambda: proc.poll() is not None)
            self.assertEqual(proc.returncode, 0)
            self.assertNotIn(b'^[', output)
            after = termios.tcgetattr(slave)
            self.assertEqual(after[3] & (termios.ECHO | termios.ICANON | termios.ISIG), before[3] & (termios.ECHO | termios.ICANON | termios.ISIG))
        finally:
            if proc.poll() is None:
                proc.kill(); proc.wait()
            os.close(master); os.close(slave)


def pty_child(directory):
    os.environ['HOME'] = directory
    for name in ('CLAUDE_CONFIG_DIR', 'CLAUDE_SECURESTORAGE_CONFIG_DIR'):
        os.environ.pop(name, None)
    f = Fixture(directory)
    for name in ('capture', 'activate_account', 'delete_account', 'clear_live_session', 'toggle_visible', 'refresh'):
        original = getattr(f.m, name)
        def record(*args, _name=name, _original=original, **kwargs):
            result = _original(*args, **kwargs)
            with open(Path(directory) / 'events.jsonl', 'a') as handle:
                handle.write(json.dumps([_name, list(args)]) + '\n')
            return result
        setattr(f.m, name, record)
    f.m.dashboard()


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--pty-child':
        pty_child(sys.argv[2])
    else:
        unittest.main()
