#!/usr/bin/env python3
"""Exercise the release runner in an isolated session (see test-native.sh)."""
import ctypes
from contextlib import contextmanager
import json
import os
import re
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import wave

import gi
gi.require_version('Gio', '2.0')
from gi.repository import Gio, GLib

PLAYER = 'org.mpris.MediaPlayer2.qingting'
OBJECT = '/org/mpris/MediaPlayer2'
INTERFACE = 'org.mpris.MediaPlayer2.Player'


def pump_until(predicate, timeout=12):
    deadline = time.monotonic() + timeout
    context = GLib.MainContext.default()
    while time.monotonic() < deadline:
        while context.pending():
            context.iteration(False)
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError('Timed out waiting for desktop state')


def command(*args, env=None):
    process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
    pump_until(lambda: process.poll() is not None)
    stdout, stderr = process.communicate()
    if process.returncode:
        raise AssertionError(f'{args[0]} failed: {stderr}')
    return stdout.strip()


def dbus(method, *args):
    return command('gdbus', 'call', '--session', '--dest', PLAYER, '--object-path', OBJECT,
                   '--method', method, *args)


def prop(name):
    return dbus('org.freedesktop.DBus.Properties.Get', INTERFACE, name)


def volume_is(expected):
    value = re.search(r'<([0-9.eE+-]+)>', prop('Volume'))
    return value is not None and abs(float(value.group(1)) - expected) < 0.000001


def windows(pid, visible=False):
    args = ['xdotool', 'search']
    if visible:
        args += ['--onlyvisible']
    args += ['--pid', str(pid)]
    process = subprocess.run(args, capture_output=True, text=True)
    return process.stdout.strip().splitlines() if process.returncode == 0 else []


def close_window(window_id):
    # WM_DELETE_WINDOW also works without a window manager in Xvfb.
    x11 = ctypes.CDLL('libX11.so.6')
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    display = x11.XOpenDisplay(None)
    assert display
    x11.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    x11.XInternAtom.restype = ctypes.c_ulong

    class Data(ctypes.Union):
        _fields_ = [('b', ctypes.c_char * 20), ('s', ctypes.c_short * 10), ('l', ctypes.c_long * 5)]

    class ClientMessage(ctypes.Structure):
        _fields_ = [('type', ctypes.c_int), ('serial', ctypes.c_ulong), ('send_event', ctypes.c_int),
                    ('display', ctypes.c_void_p), ('window', ctypes.c_ulong),
                    ('message_type', ctypes.c_ulong), ('format', ctypes.c_int), ('data', Data)]

    class Event(ctypes.Union):
        _fields_ = [('client', ClientMessage), ('padding', ctypes.c_long * 24)]

    event = Event()
    event.client.type = 33
    event.client.display = display
    event.client.window = int(window_id)
    event.client.message_type = x11.XInternAtom(display, b'WM_PROTOCOLS', False)
    event.client.format = 32
    event.client.data.l[0] = x11.XInternAtom(display, b'WM_DELETE_WINDOW', False)
    x11.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_long, ctypes.POINTER(Event)]
    x11.XSendEvent(display, int(window_id), False, 0, ctypes.byref(event))
    x11.XFlush.argtypes = [ctypes.c_void_p]
    x11.XFlush(display)
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    x11.XCloseDisplay(display)


class TrayHost:
    XML = '''<node><interface name="org.kde.StatusNotifierWatcher">
    <method name="RegisterStatusNotifierItem"><arg type="s" direction="in"/></method>
    <method name="RegisterStatusNotifierHost"><arg type="s" direction="in"/></method>
    <property name="RegisteredStatusNotifierItems" type="as" access="read"/>
    <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
    <property name="ProtocolVersion" type="i" access="read"/>
    <signal name="StatusNotifierItemRegistered"><arg type="s"/></signal>
    <signal name="StatusNotifierHostRegistered"/>
    </interface></node>'''

    def __init__(self):
        self.items = []
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.node = Gio.DBusNodeInfo.new_for_xml(self.XML)
        self.registration = self.bus.register_object('/StatusNotifierWatcher', self.node.interfaces[0],
                                                     self.method, self.get_property, None)
        self.ready = False
        self.owner = Gio.bus_own_name_on_connection(self.bus, 'org.kde.StatusNotifierWatcher',
            Gio.BusNameOwnerFlags.NONE, lambda *args: setattr(self, 'ready', True), None)
        pump_until(lambda: self.ready)

    def method(self, bus, sender, path, interface, method, params, invocation):
        if method == 'RegisterStatusNotifierItem':
            name = params.unpack()[0]
            item = sender + name if name.startswith('/') else name + '/StatusNotifierItem'
            self.items.append(item)
            invocation.return_value(None)
            bus.emit_signal(None, '/StatusNotifierWatcher', interface, 'StatusNotifierItemRegistered',
                            GLib.Variant('(s)', (item,)))
        else:
            invocation.return_value(None)

    def get_property(self, bus, sender, path, interface, name):
        if name == 'RegisteredStatusNotifierItems':
            return GLib.Variant('as', self.items)
        if name == 'IsStatusNotifierHostRegistered':
            return GLib.Variant('b', True)
        return GLib.Variant('i', 0)

    def stop(self):
        Gio.bus_unown_name(self.owner)
        self.bus.unregister_object(self.registration)


@contextmanager
def private_keyring(env, log):
    # A fresh graphical test session has no PAM login to unlock a keyring.
    # Keep the provider and its disposable credentials inside the test home.
    if not shutil.which('gnome-keyring-daemon'):
        raise AssertionError('Install gnome-keyring before running native tests')
    runtime = Path(env['HOME']) / 'keyring-runtime'
    runtime.mkdir(mode=0o700)
    keyring = subprocess.Popen(
        ['gnome-keyring-daemon', '--foreground', '--unlock', '--components=secrets'],
        env=dict(env, XDG_RUNTIME_DIR=str(runtime)), stdin=subprocess.PIPE,
        stdout=log, stderr=log)
    keyring.stdin.write(b'qingting-disposable-native-test')
    keyring.stdin.close()
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)

    def unlocked():
        assert keyring.poll() is None, 'Private test keyring exited'
        try:
            result = bus.call_sync(
                'org.freedesktop.secrets', '/org/freedesktop/secrets/aliases/default',
                'org.freedesktop.DBus.Properties', 'Get',
                GLib.Variant('(ss)', ('org.freedesktop.Secret.Collection', 'Locked')),
                None, Gio.DBusCallFlags.NO_AUTO_START, 1000, None)
            return result.unpack()[0] is False
        except GLib.Error:
            return False

    try:
        pump_until(unlocked)
        yield
    finally:
        if keyring.poll() is None:
            keyring.terminate()
            try:
                keyring.wait(timeout=5)
            except subprocess.TimeoutExpired:
                keyring.kill()
                keyring.wait(timeout=5)


def check(executable, tray):
    host = TrayHost() if tray else None
    with tempfile.TemporaryDirectory(prefix='qingting-native-test-') as directory:
        env = os.environ.copy()
        env.update(HOME=directory, XDG_CONFIG_HOME=directory + '/config', XDG_DATA_HOME=directory + '/data',
                   XDG_CACHE_HOME=directory + '/cache', GDK_BACKEND='x11',
                   LIBGL_ALWAYS_SOFTWARE='1', WEBKIT_DISABLE_DMABUF_RENDERER='1')
        with open(directory + '/runner.log', 'w+') as log, private_keyring(env, log):
            app = subprocess.Popen([executable], env=env, stdout=log, stderr=log)
            try:
                pump_until(lambda: windows(app.pid, True))
                window = windows(app.pid, True)[0]
                # Wait for Dart bootstrap, then exercise real method channels.
                pump_until(lambda: app.poll() is None and bool(dbus('org.mpris.MediaPlayer2.Raise')))
                assert 'Stopped' in prop('PlaybackStatus')
                dbus('org.freedesktop.DBus.Properties.Set', INTERFACE, 'Volume', '<0.37>')
                pump_until(lambda: volume_is(0.37))
                dbus('org.freedesktop.DBus.Properties.Set', INTERFACE, 'Shuffle', '<true>')
                pump_until(lambda: 'true' in prop('Shuffle'))
                dbus('org.freedesktop.DBus.Properties.Set', INTERFACE, 'LoopStatus', "<'Track'>")
                pump_until(lambda: 'Track' in prop('LoopStatus'))
                dbus(INTERFACE + '.Pause')
                dbus(INTERFACE + '.Seek', '1000000')
                # A second invocation must activate the same instance.
                second = subprocess.Popen([executable], env=env, stdout=log, stderr=log)
                pump_until(lambda: second.poll() is not None)
                assert second.returncode == 0
                assert app.poll() is None
                if host:
                    pump_until(lambda: bool(host.items))
                close_window(window)
                if tray:
                    pump_until(lambda: not windows(app.pid, True))
                    assert app.poll() is None, 'Tray close must keep playback process alive'
                    dbus('org.mpris.MediaPlayer2.Raise')
                    pump_until(lambda: windows(app.pid, True))
                    close_window(window)
                    pump_until(lambda: not windows(app.pid, True))
                    host.stop()
                    host = None
                    pump_until(lambda: windows(app.pid, True))
                    dbus('org.mpris.MediaPlayer2.Quit')
                pump_until(lambda: app.poll() is not None, timeout=20)
                assert app.returncode == 0
                prefs = Path(directory + '/config/qingting/desktop.ini').read_text()
                assert 'width=' in prefs and 'height=' in prefs and 'closeToTray=true' in prefs
                if not tray and shutil.which('pulseaudio') and shutil.which('pactl'):
                    check_playback(executable, directory, env, log)
                log.seek(0)
                content = log.read()
                assert 'CRITICAL' not in content, content
                print('PASS: ' + ('tray hide/raise/host loss' if tray else 'no tray close exits') +
                      ', MPRIS controls, single instance, saved window state')
            except Exception:
                if app.poll() is None:
                    print('Current volume:', prop('Volume'), file=sys.stderr)
                log.seek(0)
                print(log.read(), file=sys.stderr)
                for path in Path(directory).rglob('*.log'):
                    if path.name != 'runner.log':
                        print(path.name + ':\n' + path.read_text(errors='replace'), file=sys.stderr)
                raise
            finally:
                if app.poll() is None:
                    app.terminate()
                    try:
                        app.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        app.kill()
                if host:
                    host.stop()


def check_playback(executable, directory, env, log):
    # The private null sinks emit silence and require no physical audio device.
    runtime = Path(directory) / 'audio-runtime'
    runtime.mkdir(mode=0o700)
    socket = str(runtime / 'pulse.sock')
    audio_env = dict(env, XDG_RUNTIME_DIR=str(runtime), PULSE_SERVER='unix:' + socket)
    audio = subprocess.Popen(['pulseaudio', '--daemonize=no', '--use-pid-file=no',
        '--exit-idle-time=-1', '-n',
        '--load=module-native-protocol-unix socket=' + socket + ' auth-anonymous=1',
        '--load=module-null-sink sink_name=speaker'],
        env=audio_env, stdout=log, stderr=log)
    app = None
    try:
        pump_until(lambda: Path(socket).exists())
        def pulse(*args):
            return command('pactl', '--server=unix:' + socket, *args, env=audio_env)
        pulse('set-default-sink', 'speaker')
        pulse('load-module', 'module-null-sink', 'sink_name=bt', 'sink_properties=device.bus=bluetooth')
        settings_file = next(Path(directory).rglob('settings.json'))
        settings = json.loads(settings_file.read_text())
        settings['autoPlayOnStartup'] = True
        settings_file.write_text(json.dumps(settings))
        song = str(Path(directory) / 'silent.wav')
        with wave.open(song, 'wb') as fixture:
            fixture.setnchannels(1)
            fixture.setsampwidth(2)
            fixture.setframerate(16000)
            fixture.writeframes(b'\0\0' * 16000 * 120)
        (settings_file.parent / 'queue.json').write_text(json.dumps({
            'currentIndex': 0, 'shuffleEnabled': False,
            'items': [{'id': 'native-test', 'title': 'Native silent fixture', 'artist': 'Test',
                       'uri': song, 'localPath': song, 'album': 'Test',
                       'lyrics': '[00:00.00]Native test'}],
        }))
        app = subprocess.Popen([executable], env=audio_env, stdout=log, stderr=log)
        pump_until(lambda: windows(app.pid, True))
        pump_until(lambda: 'Playing' in prop('PlaybackStatus'))
        pump_until(lambda: 'true' in prop('CanSeek'))
        assert 'Native silent fixture' in prop('Metadata')
        dbus(INTERFACE + '.Pause')
        pump_until(lambda: 'Paused' in prop('PlaybackStatus'))
        dbus(INTERFACE + '.Seek', '5000000')
        pump_until(lambda: int(re.search(r'int64 ([0-9]+)', prop('Position')).group(1)) >= 4900000)
        dbus(INTERFACE + '.Play')
        pump_until(lambda: 'Playing' in prop('PlaybackStatus'))
        def app_stream():
            inputs = json.loads(pulse('--format=json', 'list', 'sink-inputs'))
            return next((item['index'] for item in inputs
                if item.get('properties', {}).get('application.process.id') == str(app.pid)), None)
        pump_until(lambda: app_stream() is not None)
        stream = str(app_stream())
        pulse('move-sink-input', stream, 'bt')
        # Give the subscription enough time to observe the Bluetooth route.
        start = time.monotonic()
        pump_until(lambda: time.monotonic() - start > 0.4)
        other = pulse('load-module', 'module-null-sink', 'sink_name=other_bt', 'sink_properties=device.bus=bluetooth')
        pulse('unload-module', other)
        start = time.monotonic()
        pump_until(lambda: time.monotonic() - start > 0.4)
        assert 'Playing' in prop('PlaybackStatus'), 'Unrelated Bluetooth sink must not pause this player'
        pulse('move-sink-input', stream, 'speaker')
        pump_until(lambda: 'Paused' in prop('PlaybackStatus'))
        dbus(INTERFACE + '.Stop')
        pump_until(lambda: 'Stopped' in prop('PlaybackStatus'))
        dbus(INTERFACE + '.Play')
        pump_until(lambda: 'Playing' in prop('PlaybackStatus'))
        dbus('org.mpris.MediaPlayer2.Quit')
        pump_until(lambda: app.poll() is not None)
        assert app.returncode == 0
        print('PASS: real silent playback, MPRIS metadata/seek/stop/replay, process audio route pause and unrelated device isolation')
    finally:
        if app is not None and app.poll() is None:
            app.terminate()
            app.wait(timeout=5)
        audio.terminate()
        audio.wait(timeout=5)


if __name__ == '__main__':
    executable = str(Path(sys.argv[1]).resolve())
    check(executable, False)
    check(executable, True)
