#!/usr/bin/env python3
"""Fail on malicious packages in an OSV-Scanner JSON report.

    osv-gate.py <report.json> <osv-scanner exit code> <label>

OSV-Scanner exits 0 (nothing found), 1 (vulnerabilities found) or higher on
errors (127 general error, 128 no packages found). Everything we scan must
contain packages, so 128 is an error too: an extraction that finds nothing
must not look like a clean result. Any MAL- advisory (OSV's malicious-package
database) fails the gate and can't be ignored: a malicious package means
rotating credentials, not accepting a risk. Other vulnerabilities are only
counted here; Trivy gates those.
"""
import json
import sys


def main():
    path, rc, label = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    if rc == 128:
        print(f"osv-gate: {label}: osv-scanner found no packages; the scan did not work", file=sys.stderr)
        return 2
    if rc not in (0, 1):
        print(f"osv-gate: {label}: osv-scanner failed (exit {rc})", file=sys.stderr)
        return 2
    try:
        with open(path) as fh:
            report = json.load(fh)
    except (OSError, ValueError) as exc:
        print(f"osv-gate: {label}: unreadable report: {exc}", file=sys.stderr)
        return 2
    if not isinstance(report, dict) or not isinstance(report.get("results"), list):
        print(f"osv-gate: {label}: unexpected report format (no results list)", file=sys.stderr)
        return 2
    if rc == 1 and not report["results"]:
        print(f"osv-gate: {label}: exit 1 but an empty report; refusing to pass", file=sys.stderr)
        return 2
    malicious, other = [], 0
    for result in report["results"]:
        source = (result.get("source") or {}).get("path", "?")
        for pkg in result.get("packages") or []:
            info = pkg.get("package") or {}
            for vuln in pkg.get("vulnerabilities") or []:
                ids = [vuln.get("id", "")] + list(vuln.get("aliases") or [])
                if any(i.startswith("MAL-") for i in ids):
                    malicious.append(f"{info.get('ecosystem')}/{info.get('name')}@{info.get('version')} "
                                     f"{vuln.get('id')} ({source})")
                else:
                    other += 1
    for line in malicious:
        print(f"osv-gate: {label}: MALICIOUS {line}", file=sys.stderr)
    print(f"osv-gate: {label}: {len(malicious)} malicious, {other} other advisories (gated by Trivy)")
    return 1 if malicious else 0


if __name__ == "__main__":
    sys.exit(main())
