#!/usr/bin/env python3
"""NearMic appliance dashboard: one page on port 80, live board + audio metrics.

Standard library only. Runs as the board user (needs the user's PipeWire and
systemd session for `nearmic status`, `pw-link`, `systemctl --user`) with
CAP_NET_BIND_SERVICE, pinned to the A53 cores at low priority so it never
competes with the audio threads on the A72 pair.

Nothing is sampled while no browser is watching: the sampler thread sleeps
until a client asked for data in the last 15 s, and the Maono input meter
(a pw-record tap) only runs during that time.
"""
import glob
import json
import math
import os
import socket
import struct
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("NEARMIC_DASH_PORT", "80"))
HERE = os.path.dirname(os.path.abspath(__file__))
HOME = os.path.expanduser("~")
NEARMIC = os.path.join(HOME, ".local/bin/nearmic")
SYS_UNITS = ["nearmic-gadget", "nearmic-cpufreq", "nearmic-wifi-watchdog.timer", "ssh",
             "systemd-networkd", "avahi-daemon", "unattended-upgrades", "nearmic-dash"]
USER_UNITS = ["pipewire", "wireplumber", "nearmic", "nearmic-link",
              "nearmic-headphone-link", "nearmic-health.timer"]

state = {"ts": 0}
lock = threading.Lock()
last_client = 0.0
levels = {"l": -120.0, "r": -120.0, "pl": -120.0, "pr": -120.0, "ok": False}


def rd(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def run(cmd, timeout=4):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


# ---------------------------------------------------------------- fast (1 s)
_prev = {}


def rate(key, value, now):
    """Per-second rate of a monotonically increasing counter."""
    old = _prev.get(key)
    _prev[key] = (value, now)
    if not old or now <= old[1]:
        return 0.0
    return max(0.0, (value - old[0]) / (now - old[1]))


def cpu_usage():
    out = []
    for line in rd("/proc/stat").splitlines():
        if not line.startswith("cpu"):
            break
        p = line.split()
        vals = list(map(int, p[1:9]))
        idle, total = vals[3] + vals[4], sum(vals)
        old = _prev.get("cpu" + p[0])
        _prev["cpu" + p[0]] = (idle, total)
        pct = 0.0
        if old and total > old[1]:
            pct = 100.0 * (1 - (idle - old[0]) / (total - old[1]))
        out.append(round(max(0.0, pct), 1))
    return out  # [all, cpu0..cpuN]


def meminfo():
    m = {}
    for line in rd("/proc/meminfo").splitlines():
        k, v = line.split(":")
        m[k] = int(v.split()[0]) * 1024
    return {
        "total": m.get("MemTotal", 0), "avail": m.get("MemAvailable", 0),
        "cached": m.get("Cached", 0) + m.get("Buffers", 0),
        "swap_total": m.get("SwapTotal", 0), "swap_free": m.get("SwapFree", 0),
    }


def psi(kind):
    line = rd("/proc/pressure/" + kind).splitlines()
    try:
        return float(line[0].split("avg10=")[1].split()[0])
    except (IndexError, ValueError):
        return 0.0


def net(now):
    out = {}
    for ifc in ("wlan0", "usb0", "end0"):
        base = "/sys/class/net/%s/" % ifc
        if not os.path.isdir(base):
            continue
        rx = int(rd(base + "statistics/rx_bytes", "0"))
        tx = int(rd(base + "statistics/tx_bytes", "0"))
        out[ifc] = {
            "up": rd(base + "operstate") == "up", "rx": rx, "tx": tx,
            "rx_rate": rate(ifc + "rx", rx, now), "tx_rate": rate(ifc + "tx", tx, now),
        }
    return out


def disk_io(now):
    for line in rd("/proc/diskstats").splitlines():
        p = line.split()
        if len(p) > 9 and p[2] == "mmcblk0":
            return {"read": rate("dr", int(p[5]) * 512, now), "write": rate("dw", int(p[9]) * 512, now)}
    return {"read": 0, "write": 0}


def nearmic_proc(now):
    """CPU % and memory of the NearMic daemon, from /proc."""
    pid = _prev.get("nm_pid")
    if not pid or not os.path.exists("/proc/%s/stat" % pid):
        pid = None
        for d in glob.glob("/proc/[0-9]*"):
            if rd(d + "/cmdline").replace("\0", " ").strip().endswith("nearmic run"):
                pid = d.rsplit("/", 1)[1]
                break
        _prev["nm_pid"] = pid
    if not pid:
        return None
    st = rd("/proc/%s/stat" % pid).rsplit(")", 1)[-1].split()
    try:
        ticks = int(st[11]) + int(st[12])
        rss = int(st[21]) * os.sysconf("SC_PAGE_SIZE")
        threads = int(st[17])
    except (IndexError, ValueError):
        return None
    cpu = 100.0 * rate("nm_cpu", ticks / os.sysconf("SC_CLK_TCK"), now)
    return {"pid": int(pid), "cpu": round(cpu, 1), "rss": rss, "threads": threads}


def fast():
    now = time.time()
    cpu = cpu_usage()
    temps = {}
    for z in glob.glob("/sys/class/thermal/thermal_zone*"):
        temps[rd(z + "/type").replace("-thermal", "")] = int(rd(z + "/temp", "0")) / 1000.0
    freq = {}
    for name, pol in (("a53", "policy0"), ("a72", "policy4")):
        b = "/sys/devices/system/cpu/cpufreq/%s/" % pol
        freq[name] = {"cur": int(rd(b + "scaling_cur_freq", "0")) // 1000,
                      "min": int(rd(b + "scaling_min_freq", "0")) // 1000,
                      "max": int(rd(b + "scaling_max_freq", "0")) // 1000,
                      "gov": rd(b + "scaling_governor")}
    st = os.statvfs("/")
    load = rd("/proc/loadavg").split()
    return {
        "ts": now, "uptime": float(rd("/proc/uptime", "0").split()[0]),
        "cpu": cpu[0] if cpu else 0, "cores": cpu[1:], "freq": freq, "temps": temps,
        "load": [float(x) for x in load[:3]], "procs": load[3] if len(load) > 3 else "",
        "mem": meminfo(), "psi": {k: psi(k) for k in ("cpu", "memory", "io")},
        "disk": {"total": st.f_blocks * st.f_frsize, "free": st.f_bavail * st.f_frsize, **disk_io(now)},
        "net": net(now), "nm_proc": nearmic_proc(now),
        "udc": rd("/sys/class/udc/fe800000.usb/state", "missing"),
        "wifi_fail": int(rd("/run/nearmic-wifi-fail", "0") or 0),
        "levels": dict(levels),
    }


# ---------------------------------------------------------------- slow (4 s)
def nearmic_status(now):
    kv = {}
    try:  # `nearmic status` prints its key=value lines on stderr
        r = subprocess.run([NEARMIC, "status"], capture_output=True, text=True, timeout=4)
        text = r.stdout + r.stderr
    except (OSError, subprocess.SubprocessError):
        text = ""
    for line in text.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            kv[k] = v
    for k in ("in_total", "out_total", "played_total"):
        try:
            kv[k + "_rate"] = round(rate("nm_" + k, int(kv[k]), now))
        except (KeyError, ValueError):
            pass
    return kv


def wifi():
    out = {"ip": "", "ssid": "", "signal": None}
    link = run(["/usr/sbin/iw", "dev", "wlan0", "link"])
    for line in link.splitlines():
        line = line.strip()
        if line.startswith("SSID:"):
            out["ssid"] = line[5:].strip()
        elif line.startswith("freq:"):
            out["freq"] = line[5:].strip().split(".")[0]
        elif line.startswith("signal:"):
            out["signal"] = int(line.split()[1])
        elif line.startswith("tx bitrate:"):
            out["tx_bitrate"] = line[11:].strip().split(" MBit")[0]
        elif line.startswith("rx bitrate:"):
            out["rx_bitrate"] = line[11:].strip().split(" MBit")[0]
        elif line.startswith("Connected to"):
            out["bssid"] = line.split()[2]
    for line in run(["ip", "-4", "-o", "addr", "show"]).splitlines():
        p = line.split()
        if len(p) > 3:
            out.setdefault("addrs", {})[p[1]] = p[3].split("/")[0]
    out["ip"] = out.get("addrs", {}).get("wlan0", "")
    gw = run(["ip", "-4", "route", "show", "default"]).split()
    out["gateway"] = gw[2] if len(gw) > 2 else ""
    return out


def usb_devices():
    devs = []
    for d in sorted(glob.glob("/sys/bus/usb/devices/[0-9]*-[0-9.]*")):
        if ":" in os.path.basename(d):
            continue
        devs.append({"name": rd(d + "/product") or rd(d + "/manufacturer") or "USB device",
                     "id": rd(d + "/idVendor") + ":" + rd(d + "/idProduct"),
                     "speed": rd(d + "/speed"), "port": os.path.basename(d)})
    return devs


def units():
    res = {}
    out = run(["systemctl", "is-active"] + SYS_UNITS).split()
    for u, s in zip(SYS_UNITS, out):
        res[u] = s
    out = run(["systemctl", "--user", "is-active"] + USER_UNITS).split()
    for u, s in zip(USER_UNITS, out):
        res[u] = s
    return res


def routes():
    text = run(["pw-link", "-l"])
    mic = hp = src = False
    cur = ""
    for line in text.splitlines():
        if not line.startswith(" "):
            cur = line.strip()
            continue
        dst = line.split("|->")[-1].strip() if "|->" in line else ""
        if not dst:
            continue
        if cur.startswith("nearmic:") and "fe800000" in dst and "playback" in dst:
            mic = True
        if "fe800000" in cur and "capture" in cur and "aono" in dst:
            hp = True
        if "aono" in cur and "capture" in cur and dst.startswith("nearmic-capture"):
            src = True
    return {"mic_to_host": mic, "host_to_headphones": hp, "maono_to_nearmic": src}


def slow():
    now = time.time()
    failed = [l.split()[0] for l in run(["systemctl", "--failed", "--no-legend", "--plain"]).splitlines() if l.split()]
    stamp = "/var/lib/apt/periodic/unattended-upgrades-stamp"
    return {
        "nearmic": nearmic_status(now), "wifi": wifi(), "usb": usb_devices(), "units": units(),
        "routes": routes(), "failed": failed,
        "quantum": run(["pw-metadata", "-n", "settings", "0", "clock.force-quantum"]).split("value:'")[-1].split("'")[0][:6],
        "reboot_required": os.path.exists("/run/reboot-required"),
        "last_upgrade": os.path.getmtime(stamp) if os.path.exists(stamp) else None,
        "emmc_life": rd("/sys/block/mmcblk0/device/life_time"),
    }


def static():
    osr = dict(l.split("=", 1) for l in rd("/etc/os-release").splitlines() if "=" in l)
    return {
        "host": socket.gethostname(), "model": rd("/proc/device-tree/model").strip("\0 "),
        "os": osr.get("PRETTY_NAME", "").strip('"'), "kernel": os.uname().release,
        "ncpu": os.cpu_count(),
        "watchdog": run(["systemctl", "show", "-p", "RuntimeWatchdogUSec", "--value"]).strip(),
    }


# ------------------------------------------------------------- level meter
def meter():
    """Peak/RMS of the Maono input while a browser is watching."""
    while True:
        if time.time() - last_client > 15:
            levels["ok"] = False
            time.sleep(1)
            continue
        node = ""
        for line in run(["pw-link", "-o"]).splitlines():
            if "aono" in line and ":capture_" in line and line.startswith("alsa_input"):
                node = line.split(":")[0]
                break
        if not node:
            levels["ok"] = False
            time.sleep(3)
            continue
        try:
            p = subprocess.Popen(["pw-record", "--target", node, "-P", "node.name=nearmic-dash-meter",
                                  "--rate", "48000", "--channels", "2", "--format", "s16", "--raw", "-"],
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        except OSError:
            time.sleep(5)
            continue
        chunk = 4800 * 4  # 100 ms of stereo s16
        try:
            while time.time() - last_client <= 15:
                buf = p.stdout.read(chunk)
                if len(buf) < chunk:
                    break
                s = struct.unpack("<%dh" % (len(buf) // 2), buf)
                for name, ch in (("l", s[0::2]), ("r", s[1::2])):
                    peak = max(1, max(abs(min(ch)), abs(max(ch))))
                    rms = max(1.0, math.sqrt(sum(x * x for x in ch[::4]) / (len(ch) // 4)))
                    levels[name] = round(20 * math.log10(rms / 32768.0), 1)
                    levels["p" + name] = round(20 * math.log10(peak / 32768.0), 1)
                levels["ok"] = True
        finally:
            p.kill()
            p.wait()
            levels["ok"] = False
        time.sleep(1)


def sampler():
    info = static()
    slow_data, slow_at = {}, 0.0
    while True:
        if time.time() - last_client > 15:
            time.sleep(0.5)
            continue
        t0 = time.time()
        try:
            data = fast()
            if t0 - slow_at >= 4:
                slow_data, slow_at = slow(), t0
            data.update(slow_data)
            data["info"] = info
            with lock:
                state.clear()
                state.update(data)
        except Exception as exc:  # keep serving the last good sample
            with lock:
                state["error"] = repr(exc)
        time.sleep(max(0.05, 1.0 - (time.time() - t0)))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        global last_client
        path = self.path.split("?")[0]
        if path == "/api":
            last_client = time.time()
            with lock:
                body = json.dumps(state).encode()
            self.send(200, "application/json", body)
        elif path == "/levels":
            last_client = time.time()
            self.send(200, "application/json", json.dumps(levels).encode())
        elif path in ("/", "/index.html"):
            try:
                with open(os.path.join(HERE, "index.html"), "rb") as f:
                    self.send(200, "text/html; charset=utf-8", f.read())
            except OSError:
                self.send(500, "text/plain", b"index.html missing")
        else:
            self.send(404, "text/plain", b"not found")


if __name__ == "__main__":
    os.environ.setdefault("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid())
    threading.Thread(target=sampler, daemon=True).start()
    threading.Thread(target=meter, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
