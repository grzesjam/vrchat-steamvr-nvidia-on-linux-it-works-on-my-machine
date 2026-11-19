#!/usr/bin/env python3
"""Steam session launcher; Linux only; no third-party dependencies."""
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

WITH_GAME = sys.argv[1] == '1'
HERE = Path(sys.argv[2])
# Set any RUN_* option to False to skip that app entirely.
RUN_BABALLONIA = False #True
RUN_VRCFACETRACKING = False
RUN_VRCVIDEOCACHER = False
APP_BABALLONIA = '4091970'
APP_VRCFACETRACKING = '3329480'
APP_VRCVIDEOCACHER = '4296960'
SUPERVISED = tuple(app for enabled, app in (
    (RUN_BABALLONIA, APP_BABALLONIA),
    (RUN_VRCFACETRACKING, APP_VRCFACETRACKING),
    (RUN_VRCVIDEOCACHER, APP_VRCVIDEOCACHER),
) if enabled)
USE_STEAM_FOR_VRCVIDEOCACHER = False  # False launches the system command below instead.
VRCVIDEOCACHER_APP = APP_VRCVIDEOCACHER
VRCVIDEOCACHER_COMMAND = 'VRCVideoCacher'
GAME = '438100'  # VRChat
POLL = 5
GRACE = 180
COOLDOWN = 60
WAIT_GAME = 300
stopping = False
launched = set()

COLOR = sys.stdout.isatty()
LEVELS = {'INFO': '36', 'OK': '32', 'WARN': '33', 'ERROR': '31', 'DEBUG': '35', 'CMD': '34'}
NAMES = {APP_BABALLONIA: 'Baballonia', APP_VRCFACETRACKING: 'VRCFaceTracking',
         APP_VRCVIDEOCACHER: 'VRCVideoCacher', '438100': 'VRChat'}

def name(app):
    return '%s (%s)' % (app, NAMES.get(app, '?'))

def log(msg, level='INFO'):
    if COLOR:
        print('\033[2m%s\033[0m \033[%sm%-5s\033[0m %s' % (
            time.strftime('[%H:%M:%S]'), LEVELS[level], level, msg), flush=True)
    else:
        print(time.strftime('[%H:%M:%S]'), '%-5s' % level, msg, flush=True)

def describe_parents(pid):
    """Return 'name(pid) <- name(pid) <- ...' to show who started a process."""
    chain = []
    for _ in range(6):
        try:
            stat = Path('/proc', str(pid), 'stat').read_text()
            comm = stat[stat.index('(') + 1:stat.rindex(')')]
            ppid = int(stat.rsplit(')', 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            break
        chain.append('%s(%d)' % (comm, pid))
        if ppid <= 1:
            break
        pid = ppid
    return ' <- '.join(chain)

def on_signal(*_):
    global stopping
    stopping = True

signal.signal(signal.SIGINT, on_signal)
signal.signal(signal.SIGTERM, on_signal)

def process_info():
    """Map (PID, Linux start-ticks) to supervised app; same-UID processes only."""
    found = {}
    for entry in os.scandir('/proc'):
        if not entry.name.isdigit():
            continue
        try:
            pid = int(entry.name)
            base = '/proc/' + entry.name
            if os.stat(base).st_uid != os.getuid():
                continue
            env = Path(base, 'environ').read_bytes().split(b'\0')
            ids = {v.split(b'=', 1)[1].decode('ascii', 'ignore') for v in env
                   if v.startswith((b'SteamAppId=', b'SteamGameId='))}
            valid = ids.intersection((*SUPERVISED, GAME) if WITH_GAME else SUPERVISED)
            if (RUN_VRCVIDEOCACHER and not USE_STEAM_FOR_VRCVIDEOCACHER and
                    VRCVIDEOCACHER_APP not in valid):
                cmdline = Path(base, 'cmdline').read_bytes().split(b'\0')
                argv0 = os.fsdecode(cmdline[0]) if cmdline and cmdline[0] else ''
                try:
                    executable = os.readlink(Path(base, 'exe'))
                except OSError:
                    executable = ''
                if (Path(argv0).name == VRCVIDEOCACHER_COMMAND or
                        Path(executable).name == VRCVIDEOCACHER_COMMAND):
                    valid.add(VRCVIDEOCACHER_APP)
            if not valid:
                continue
            # /proc/PID/stat's comm can contain spaces and parentheses.
            stat = Path(base, 'stat').read_text().rsplit(')', 1)[1].split()
            start_ticks = int(stat[19])  # field 22 (post-comm zero-based index 19)
            found[(pid, start_ticks)] = sorted(valid)[0]
        except (OSError, ValueError, IndexError, PermissionError):
            pass
    return found

def launch(app):
    system_command = (app == VRCVIDEOCACHER_APP and
                      not USE_STEAM_FOR_VRCVIDEOCACHER)
    if app == GAME and (not WITH_GAME or GAME in launched):
        log('Refusing to (re)start %s; VRChat is never restarted.' % name(GAME), 'WARN')
        return time.monotonic()
    launched.add(app)
    command = [VRCVIDEOCACHER_COMMAND] if system_command else ['steam', '-applaunch', app]
    log('Launching %s: $ %s' % (name(app), ' '.join(command)), 'CMD')
    try:
        proc = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                start_new_session=True)
        log('Launch command started (PID %d)' % proc.pid, 'OK')
    except OSError as exc:
        log(('System command launch error: ' if system_command else 'Steam launch error: ') + str(exc), 'ERROR')
    return time.monotonic()

def open_clock(pidfile):
    wrapper = str(HERE / 'clock-tui.sh')
    launchers = [
        ('x-terminal-emulator', ['x-terminal-emulator', '-e', 'bash', wrapper, pidfile]),
        ('konsole', ['konsole', '-e', 'bash', wrapper, pidfile]),
        ('gnome-terminal', ['gnome-terminal', '--', 'bash', wrapper, pidfile]),
        ('xfce4-terminal', ['xfce4-terminal', '--', 'command', 'bash ' + shutil.which('bash') + ' ' + shlex_quote(wrapper) + ' ' + shlex_quote(pidfile)]),
        ('kitty', ['kitty', 'bash', wrapper, pidfile]),
        ('alacritty', ['alacritty', '-e', 'bash', wrapper, pidfile]),
        ('xterm', ['xterm', '-e', 'bash', wrapper, pidfile]),
    ]
    for exe, args in launchers:
        if shutil.which(exe):
            log('Opening NVIDIA clock TUI in an independent root terminal ($ sudo -n %s)' % ' '.join(args), 'CMD')
            # sudo is invoked here, from the launcher's original terminal, so
            # its existing authentication applies even with per-TTY sudo tickets.
            # Running the terminal as root means the clock script needs no sudo.
            subprocess.Popen(['sudo', '-n', *args], stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return
    log('No supported terminal emulator; skipping NVIDIA clock TUI.', 'WARN')

def shlex_quote(s):
    import shlex
    return shlex.quote(s)

def terminate_session(owned, pidfile):
    log('Ctrl+C / stop: closing session-owned apps and clock TUI.', 'WARN')
    active = process_info()
    targets = [pid for (pid, start), app in owned.items()
               if active.get((pid, start)) == app]
    # No broad pkill, Steam client shutdown, or killing by app ID alone.
    for pid in targets:
        try:
            os.kill(pid, signal.SIGTERM)
            log('Sent SIGTERM to PID %d' % pid, 'DEBUG')
        except ProcessLookupError:
            pass
        except PermissionError:
            log('Permission denied stopping PID ' + str(pid), 'ERROR')
    try:
        clock_pid = int(Path(pidfile).read_text().strip())
        cmd = Path('/proc', str(clock_pid), 'cmdline').read_bytes()
        if b'nvidia-clock.sh' in cmd:
            os.kill(clock_pid, signal.SIGTERM)
    except (OSError, ValueError, ProcessLookupError):
        pass
    log('Sent SIGTERM to identified session processes; Steam itself was left running.', 'OK')

# Capture baseline before any launches; these are never owned by the session.
initial = process_info()
for (pid, _), app in sorted(initial.items()):
    log('Already running before launch: PID %d %s' % (pid, name(app)), 'DEBUG')
owned = {}  # (pid, process start-ticks) -> app ID
pending = {}  # app -> last launch time; attribute new processes only within launch window
seen = {app: app in initial.values() for app in SUPERVISED}
last = {}
previous = initial
owned_game = False
game_seen = False
game_end = None
with tempfile.TemporaryDirectory(prefix='vrchat-session-') as tmp:
    clockfile = str(Path(tmp) / 'clock.pid')
    open_clock(clockfile)
    try:
        for app in SUPERVISED:
            if app in initial.values():
                log(name(app) + ' already running externally; will not claim or close it.', 'WARN')
                last[app] = 0
            else:
                pending[app] = last[app] = launch(app)
            if app == APP_BABALLONIA:
                log('Waiting 10 seconds...')
                time.sleep(10)
        if WITH_GAME:
            if GAME in process_info().values():
                log(name(GAME) + ' already running externally; leaving it alone.', 'WARN')
            else:
                pending[GAME] = last[GAME] = launch(GAME)
                owned_game = True
        else:
            log('VRChat launch disabled; this script will never start ' + name(GAME) + '.', 'DEBUG')
        log('Monitoring every %d seconds. Ctrl+C closes identified session-owned processes.' % POLL)
        while not stopping:
            now = time.monotonic()
            active = process_info()
            for key, app in active.items():
                if key in previous:
                    continue
                log('New process PID %d %s, started by: %s'
                    % (key[0], name(app), describe_parents(key[0])), 'DEBUG')
                # Attributing newly found processes to the session is best-effort;
                # simultaneous manual Steam starts are ambiguous.
                if key not in initial and app in pending and now - pending[app] <= GRACE:
                    owned[key] = app
                    log('Tracking session process PID %s %s' % (key[0], name(app)), 'OK')
            for key, app in previous.items():
                if key not in active:
                    log('Process exited: PID %d %s' % (key[0], name(app)), 'DEBUG')
            previous = active
            for app in SUPERVISED:
                present = app in active.values()
                if present:
                    if not seen[app]:
                        log(name(app) + ' is running.', 'OK')
                    seen[app] = True
                elif seen[app] and now - last[app] >= COOLDOWN:
                    log(name(app) + ' exited; restarting.', 'WARN')
                    pending[app] = last[app] = launch(app)
                    seen[app] = False
                elif not seen[app] and now - last[app] >= GRACE:
                    log('%s not detected for %ds; retrying.' % (name(app), GRACE), 'WARN')
                    pending[app] = last[app] = launch(app)
            if owned_game:
                present = GAME in active.values()
                if present:
                    game_seen = True
                    game_end = None
                elif game_seen and game_end is None:
                    game_end = now
                    log(name(GAME) + ' exited; ending monitoring in 5 minutes without closing other apps.', 'WARN')
                if game_end is not None and now - game_end >= WAIT_GAME:
                    log('5-minute timeout reached; leaving other apps running.')
                    break
            time.sleep(POLL)
    finally:
        if stopping:
            terminate_session(owned, clockfile)
        else:
            log('Monitoring finished; no apps closed.', 'OK')
