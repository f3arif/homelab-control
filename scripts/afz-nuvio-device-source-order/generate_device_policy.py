"""Create local-only AFZ device class overrides from Tailscale peer names.

By default prints counts only. --apply writes device-policy.json if absent.
Never uploads peer IDs, IP addresses, or login details to GitHub.
"""
import argparse
import ipaddress
import json
import pathlib
import subprocess
import sys

STAGE=pathlib.Path(__file__).resolve().parent
sys.path.insert(0,str(STAGE))
from device_source_order import device_name_category

def generate():
    result=subprocess.run(["tailscale.exe","status","--json"],
                          capture_output=True,text=True,timeout=12,check=True)
    obj=json.loads(result.stdout)
    classes={"phone":set(),"tv":set()}
    other=0
    for peer in (obj.get("Peer") or {}).values():
        label=device_name_category(peer.get("HostName") or peer.get("DNSName") or "")
        if label not in classes:
            other+=1
            continue
        for ip in peer.get("TailscaleIPs",[]):
            try:
                item=ipaddress.ip_address(ip)
                if isinstance(item,ipaddress.IPv4Address) and item in ipaddress.ip_network("100.64.0.0/10"):
                    classes[label].add(str(item))
            except ValueError:
                pass
    return {"schema_version":1,"purpose":"Local peer-class overrides for source order",
            "phone":sorted(classes["phone"]),"tv":sorted(classes["tv"]),
            "unknown_behavior":"pass original streams unchanged"},other

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--apply",action="store_true")
    args=parser.parse_args()
    policy,other=generate()
    print("PHONE_PEERS",len(policy["phone"]),"TV_PEERS",len(policy["tv"]),
          "UNKNOWN_PEERS",other,"NO_PRIVATE_IPS_PRINTED",True)
    if not policy["phone"] or not policy["tv"]:
        raise RuntimeError("No recognized phone/TV; add explicit device names first")
    dest=STAGE/"device-policy.json"
    if args.apply:
        if dest.exists():
            raise RuntimeError("Policy already exists; refusing to replace overrides")
        dest.write_text(json.dumps(policy,indent=2),encoding="utf-8")
        print("LOCAL_POLICY_SAVED",True)
    else:
        print("DRY_RUN_NO_CHANGE",True)

if __name__=="__main__":
    main()
