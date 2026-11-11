"""Emit bounded /etc/hosts entries only when a CI mirror cannot resolve.

Used on ephemeral GitHub Linux runners. HTTPS validates the fallback resolver;
APT still validates the original Ubuntu archive signatures and package hashes.
This helper never changes the resolver, repositories or files itself.
"""
import ipaddress
import json
import subprocess
import sys
import urllib.request


def main():
    entries = []
    for host in ("azure.archive.ubuntu.com", "archive.ubuntu.com", "security.ubuntu.com"):
        try:
            result = subprocess.run(
                ["getent", "ahostsv4", host], stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, timeout=8, check=False,
            )
            if result.returncode == 0:
                continue
        except (OSError, subprocess.TimeoutExpired):
            pass
        request = urllib.request.Request(
            "https://dns.google/resolve?name=" + host + "&type=A",
            headers={"Accept": "application/dns-json"},
        )
        with urllib.request.urlopen(request, timeout=15) as response:
            raw = response.read(65537)
        if len(raw) > 65536:
            raise ValueError("Mirror DNS response exceeds bound")
        document = json.loads(raw)
        if document.get("Status") != 0:
            raise ValueError("Mirror DNS resolution failed")
        addresses = []
        for answer in document.get("Answer", []):
            if answer.get("type") != 1:
                continue
            address = ipaddress.IPv4Address(answer["data"])
            if not address.is_global:
                raise ValueError("Non-public Ubuntu mirror address rejected")
            if address not in addresses:
                addresses.append(address)
        if not addresses:
            raise ValueError("Mirror DNS response contains no public IPv4 address")
        entries.extend(f"{address} {host}" for address in addresses[:4])
        print(f"Resolved official Ubuntu mirror through HTTPS fallback: {host}", file=sys.stderr)
    for entry in entries:
        print(entry)


if __name__ == "__main__":
    main()
