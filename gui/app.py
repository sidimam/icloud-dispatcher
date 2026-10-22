#!/usr/bin/env python3
"""iCloudpd-dispatcher GUI: utenti = container icloudpd, associazioni Telegram, cosa scaricare, rinnovo 2FA."""
import json, os, re, subprocess, shutil, datetime, html
from flask import Flask, request, redirect, url_for, render_template, flash, abort

APP_DIR = os.environ.get("APP_DIR", "/app"); CFG = os.path.join(APP_DIR, "config.json")
TOKEN = os.environ.get("TELEGRAM_TOKEN", ""); PORT = int(os.environ.get("GUI_PORT", "8787"))
app = Flask(__name__, template_folder=os.path.join(os.path.dirname(__file__), "templates")); app.secret_key = os.urandom(16)

def cfg(): return json.load(open(CFG))
def save(c): json.dump(c, open(CFG, "w"), indent=2, ensure_ascii=False)
def sh(cmd, timeout=60):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout); return r.returncode, r.stdout.strip(), r.stderr.strip()
def dexec(c, cmd, timeout=60): return sh(f"docker exec {c} sh -c {json.dumps(cmd)}", timeout)
def inspect(c):
    rc, out, _ = sh(f"docker inspect {c}");
    return json.loads(out)[0] if rc == 0 and out else None
def env_of(info): return dict(e.split("=", 1) for e in info["Config"]["Env"] if "=" in e)
def mounts(info): return {m["Destination"]: m["Source"] for m in info.get("Mounts", [])}
def conf_path(info):
    src = mounts(info).get("/config");  # percorso host → nel nostro container è sotto /appdata
    if not src: return None
    p = cfg()["paths"]
    return src.replace("/mnt/user/appdata", p["appdata"], 1) + "/icloudpd.conf"
def read_conf(path):
    d = {}
    try:
        for line in open(path):
            if "=" in line and not line.startswith("#"): k, v = line.rstrip("\n").split("=", 1); d[k] = v
    except FileNotFoundError: pass
    return d
def write_conf(path, updates):
    lines = open(path).read().splitlines() if os.path.exists(path) else []; seen = set()
    for i, l in enumerate(lines):
        k = l.split("=", 1)[0]
        if k in updates: lines[i] = f"{k}={updates[k]}"; seen.add(k)
    for k, v in updates.items():
        if k not in seen: lines.append(f"{k}={v}")
    open(path, "w").write("\n".join(lines) + "\n")
def tpl_path(c): return os.path.join(cfg()["paths"]["templates"], f"my-{c}.xml")
def tpl_set(c, key, value):
    p = tpl_path(c)
    if not os.path.exists(p): return False
    s = open(p).read()
    pat = re.compile(r'(<Config [^>]*Target="%s"[^>]*?)(/>|>[^<]*</Config>)' % re.escape(key))
    if pat.search(s): s = pat.sub(lambda m: m.group(1) + f">{html.escape(str(value))}</Config>", s, count=1)
    else: s = s.replace("</Container>", f'  <Config Name="{key}" Target="{key}" Default="" Mode="" Description="" Type="Variable" Display="advanced" Required="false" Mask="false">{html.escape(str(value))}</Config>\n</Container>')
    open(p, "w").write(s); return True
def telegram(chat, text):
    if TOKEN and chat: sh(f"curl -s -X POST https://api.telegram.org/bot{TOKEN}/sendMessage -d chat_id={chat} --data-urlencode text={json.dumps(text)} >/dev/null", 20)
def cookie_name(c): return dexec(c, 'ls /config | grep -E "^[a-z0-9]+(com|it)$" | head -1')[1]
def auth_running(c): return dexec(c, "pgrep -f authenticate.exp >/dev/null")[0] == 0
def start_auth(c):
    ck = cookie_name(c)
    dexec(c, f"rm -f /config/{ck} /config/{ck}.session; mkdir -p /tmp/icloudpd; : > /tmp/icloudpd/expect_input.txt; chmod 666 /tmp/icloudpd/expect_input.txt; nohup /usr/bin/expect /opt/authenticate.exp >/tmp/icloudpd/reauth.log 2>&1 &")
def send_code(c, code): dexec(c, f"printf '%s\\n' '{code}' >> /tmp/icloudpd/expect_input.txt")

def user_view(name, u):
    c = u["container"]; info = inspect(c); v = {"name": name, "label": u.get("label", name), "container": c, "chat_id": u.get("chat_id", ""), "exists": info is not None}
    if not info: return v
    e = env_of(info); conf = read_conf(conf_path(info) or "") ; g = lambda k, d="": conf.get(k) or e.get(k) or d
    v.update(apple_id=g("apple_id"), photo_library=g("photo_library", "PrimarySync"), photo_album=g("photo_album"), folder_structure=g("folder_structure"),
             tg_chat=g("telegram_chat_id"), notification_days=g("notification_days"), running=info["State"]["Running"], health=info["State"].get("Health", {}).get("Status", ""),
             photos_host=mounts(info).get("/home/user/iCloud", ""), config_host=mounts(info).get("/config", ""), image=info["Config"]["Image"])
    if v["running"]:
        v["days"] = dexec(c, "cat /config/DAYS_REMAINING 2>/dev/null")[1]; v["auth"] = auth_running(c)
        rc, last, _ = sh(f"docker logs --since 72h {c} 2>&1 | grep -E 'Downloaded /|Check successful|New files detected|Waiting for' | tail -1", 30); v["last"] = re.sub(r"^\S+ \S+ +\w+ +", "", last)[:120]
    return v

@app.route("/")
def index():
    c = cfg(); users = [user_view(n, u) for n, u in c["users"].items()]
    return render_template("index.html", users=users, cfg=c)
@app.post("/u/<name>/auth")
def u_auth(name):
    c = cfg(); u = c["users"].get(name) or abort(404)
    start_auth(u["container"]); telegram(u.get("chat_id") or c.get("default_chat_id"), f"🔐 {name}: riautenticazione avviata dalla GUI. Apple invia il codice a 6 cifre; rispondi con: #{name} 123456")
    flash(f"Riautenticazione avviata su {u['container']}: inserisci il codice Apple qui sotto o in Telegram con #{name} 123456"); return redirect(url_for("index"))
@app.post("/u/<name>/code")
def u_code(name):
    c = cfg(); u = c["users"].get(name) or abort(404); code = re.sub(r"\D", "", request.form.get("code", ""))
    if len(code) != 6: flash("Codice non valido: servono 6 cifre"); return redirect(url_for("index"))
    if not auth_running(u["container"]): flash(f"{name}: nessuna autenticazione in corso, prima «Riautentica»"); return redirect(url_for("index"))
    send_code(u["container"], code); flash(f"Codice consegnato a {u['container']}: verifica tra ~30 s nei giorni rimanenti"); return redirect(url_for("index"))
@app.post("/u/<name>/restart")
def u_restart(name):
    u = cfg()["users"].get(name) or abort(404); sh(f"docker restart {u['container']}", 120); flash(f"{u['container']} riavviato: ricontrolla iCloud subito"); return redirect(url_for("index"))
@app.post("/u/<name>/settings")
def u_settings(name):
    c = cfg(); u = c["users"].get(name) or abort(404); f = request.form; info = inspect(u["container"]) or abort(404)
    upd = {k: f.get(k, "").strip() for k in ("photo_library", "photo_album", "folder_structure", "telegram_chat_id", "notification_days")}
    upd = {k: v for k, v in upd.items() if v != "" or k in ("photo_album",)}
    write_conf(conf_path(info), upd)
    for k, v in upd.items(): tpl_set(u["container"], k, v)
    u["label"] = f.get("label", u.get("label", name)).strip() or name; u["chat_id"] = f.get("telegram_chat_id", "").strip(); save(c)
    sh(f"docker restart {u['container']}", 120); flash(f"{name}: impostazioni salvate (conf + template Unraid), container riavviato"); return redirect(url_for("index"))
@app.post("/u/<name>/delete")
def u_delete(name):
    c = cfg(); u = c["users"].pop(name, None) or abort(404); c["aliases"] = {a: n for a, n in c["aliases"].items() if n != name}; save(c)
    flash(f"{name}: tolto dalla GUI e dal bot (il container {u['container']} e le sue cartelle restano: gestiscili da Unraid)"); return redirect(url_for("index"))
@app.route("/new", methods=["GET", "POST"])
def new():
    c = cfg()
    if request.method == "GET": return render_template("new.html", cfg=c, bases=[u["container"] for u in c["users"].values() if inspect(u["container"])])
    f = request.form; name = re.sub(r"[^a-z0-9]", "", f["name"].lower()); short = re.sub(r"[^A-Za-z0-9]", "", f["short"]) or name
    cont = f"iCloudpd-{short}"; base = f["base"]; apple = f["apple_id"].strip(); chat = f.get("chat_id", "").strip(); lib = f.get("photo_library", "PrimarySync").strip() or "PrimarySync"
    if not name or not apple or name in c["users"]: flash("Dati mancanti o nome già usato"); return redirect(url_for("new"))
    p = c["paths"]; d = c["defaults"]; appdata = f"{p['appdata']}/icloudpd-{short.lower()}"; photos = f"{p['photos']}/{short}"
    os.makedirs(appdata, exist_ok=True); os.makedirs(photos, exist_ok=True); shutil.chown(appdata, int(d["user_id"]), int(d["group_id"])); shutil.chown(photos, int(d["user_id"]), int(d["group_id"]))
    binfo = inspect(base); benv = env_of(binfo); bm = mounts(binfo)
    env = {**{k: v for k, v in benv.items() if k not in ("PATH", "HOME", "HOSTNAME")}, "apple_id": apple, "photo_library": lib, "photo_album": f.get("photo_album", "").strip(), "TZ": d["tz"],
           "folder_structure": f.get("folder_structure", d["folder_structure"]).strip() or d["folder_structure"], "user": d["user"], "user_id": d["user_id"], "group": d["group"], "group_id": d["group_id"],
           "notification_type": "telegram", "telegram_token": TOKEN, "telegram_chat_id": chat or benv.get("telegram_chat_id", ""), "telegram_polling": "false", "notification_days": d["notification_days"], "download_path": "/home/user/iCloud"}
    host_appdata = appdata.replace(p["appdata"], "/mnt/user/appdata", 1); host_photos = photos.replace(p["photos"], "/mnt/user/media/photos", 1)
    # template Unraid dal container base
    bt = tpl_path(base)
    if os.path.exists(bt):
        s = open(bt).read(); s = re.sub(r"<Name>[^<]*</Name>", f"<Name>{cont}</Name>", s)
        s = s.replace(bm["/config"], host_appdata).replace(bm["/home/user/iCloud"].rstrip("/"), host_photos)
        open(tpl_path(cont), "w").write(s)
        for k in ("apple_id", "photo_library", "photo_album", "folder_structure", "telegram_chat_id", "notification_days", "user", "user_id", "group", "group_id", "TZ"): tpl_set(cont, k, env[k])
    envs = " ".join(f"-e {json.dumps(k + '=' + v)}" for k, v in env.items())
    labels = f'-l net.unraid.docker.managed=dockerman -l net.unraid.docker.icon={json.dumps(binfo["Config"]["Labels"].get("net.unraid.docker.icon", ""))}'
    rc, out, err = sh(f"docker run -d --name {cont} --restart=no --net=bridge {labels} {envs} -v {host_appdata}:/config -v {host_photos}:/home/user/iCloud {binfo['Config']['Image']}", 120)
    if rc != 0: flash(f"docker run fallito: {err[-300:]}"); return redirect(url_for("new"))
    c["users"][name] = {"container": cont, "label": f.get("label", name).strip() or name, "chat_id": chat}; c["aliases"][short.lower()] = name; save(c)
    flash(f"{cont} creato e avviato: ora il primo login Apple. Da Unraid: docker exec -it {cont} sync-icloud.sh --Initialise (password + codice 2FA). Autostart: attivalo dalla pagina Docker di Unraid.")
    return redirect(url_for("index"))
@app.route("/healthz")
def healthz(): return "ok"
if __name__ == "__main__": app.run(host="0.0.0.0", port=PORT, debug=False)
