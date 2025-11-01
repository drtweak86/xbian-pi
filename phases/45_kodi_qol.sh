
#!/usr/bin/env bash
set -euo pipefail
USER="xbian"; KODI_HOME="/home/${USER}/.kodi"; USERDATA="${KODI_HOME}/userdata"
AE="${USERDATA}/autoexec.py"; AED="${USERDATA}/autoexec_done.py"
mkdir -p "$USERDATA"
[ -f "$AED" ] && { echo "[qol] Already applied"; exit 0; }
cat >"$AE"<<'PY'
# QoL for Kodi; runs once then disables itself
import json, os, xbmc, shutil
def jrpc(m,p=None): 
    r=xbmc.executeJSONRPC(json.dumps({"jsonrpc":"2.0","id":1,"method":m,"params":p or {}}))
    try: return json.loads(r)
    except Exception: return {}
def setv(k,v): 
    try: jrpc("Settings.SetSettingValue",{"setting":k,"value":v})
    except Exception: pass
def getv(k):
    try: return jrpc("Settings.GetSettingValue",{"setting":k}).get("result",{}).get("value",None)
    except Exception: return None
setv("videoscreen.adjustrefreshrate",1)
setv("videoscreen.hqscalers",10)
setv("videoplayer.smoothvideo",False)
setv("audiooutput.passthrough",True)
adev=getv("audiooutput.audiodevice")
if isinstance(adev,str) and adev: setv("audiooutput.passthroughdevice",adev)
for k in ["audiooutput.ac3passthrough","audiooutput.eac3passthrough","audiooutput.dtspassthrough","audiooutput.dtshdpassthrough","audiooutput.truehdpassthrough"]:
    setv(k,True)
setv("audiooutput.eac3transcode",True)
try:
    dev=getv("audiooutput.passthroughdevice") or "Auto"
    xbmc.executebuiltin('Notification(QoL,Refresh=Start/Stop · HQ=10 · Passthrough=On · Dev={},9000)'.format(dev))
except Exception: pass
try:
    SELF=xbmc.translatePath('special://profile/autoexec.py')
    DONE=xbmc.translatePath('special://profile/autoexec_done.py')
    if os.path.exists(SELF): shutil.move(SELF,DONE)
except Exception: pass
PY
chown "${USER}:${USER}" "$AE"; chmod 0644 "$AE"
echo "[qol] Autoexec staged"
