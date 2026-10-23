#!/usr/bin/env python3
"""Pull a work item from Azure DevOps and turn it into docs/specs/product-spec.md.

This is what removes "manually put my requirement into a folder": the requirement
now comes straight from the work item that triggered the run. Uses the ADO REST
API directly (no SDK) so it has no dependencies beyond `requests`.

Env required: ADO_ORG, ADO_PROJECT, ADO_PAT
"""
from __future__ import annotations
import argparse, base64, html, os, re, sys, json
import urllib.request


def _get(url: str, pat: str) -> dict:
    token = base64.b64encode(f":{pat}".encode()).decode()
    req = urllib.request.Request(url, headers={"Authorization": f"Basic {token}"})
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read().decode())


def _strip_html(s: str) -> str:
    if not s:
        return ""
    s = re.sub(r"<br\s*/?>", "\n", s, flags=re.I)
    s = re.sub(r"</(p|div|li)>", "\n", s, flags=re.I)
    s = re.sub(r"<li>", "- ", s, flags=re.I)
    s = re.sub(r"<[^>]+>", "", s)              # drop remaining tags
    return html.unescape(s).strip()


def build_spec(fields: dict, wid: str) -> str:
    title = fields.get("System.Title", f"Work item {wid}")
    desc = _strip_html(fields.get("System.Description", ""))
    accept = _strip_html(fields.get("Microsoft.VSTS.Common.AcceptanceCriteria", ""))
    wtype = fields.get("System.WorkItemType", "")

    parts = [f"# Product Spec — {title}", ""]
    parts += [f"> Sourced from Azure DevOps {wtype} #{wid}. Do not hand-edit; "
              f"re-run the pipeline to refresh.", ""]
    parts += ["## Requirement", "", desc or "_No description on the work item._", ""]
    parts += ["## Acceptance criteria", ""]
    if accept:
        # normalize each line into a checklist item for Agent D (QA)
        for line in [l for l in accept.splitlines() if l.strip()]:
            line = line.lstrip("-* ").strip()
            parts.append(f"1. {line}")
    else:
        parts.append("_No acceptance criteria on the work item — QA will flag "
                     "this as needs_human_review._")
    parts += ["", "## Traceability", "",
              f"- Azure DevOps work item: #{wid}",
              f"- Branch: feature/wi-{wid}"]
    return "\n".join(parts) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--id", required=True)
    ap.add_argument("--out", default="docs/specs/product-spec.md")
    args = ap.parse_args()

    org = os.environ["ADO_ORG"]
    project = os.environ["ADO_PROJECT"]
    pat = os.environ["ADO_PAT"]

    url = (f"https://dev.azure.com/{org}/{project}/_apis/wit/workitems/"
           f"{args.id}?api-version=7.1")
    data = _get(url, pat)
    fields = data.get("fields", {})

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as f:
        f.write(build_spec(fields, args.id))
    print(f"Wrote {args.out} from work item #{args.id}: "
          f"{fields.get('System.Title','(untitled)')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
