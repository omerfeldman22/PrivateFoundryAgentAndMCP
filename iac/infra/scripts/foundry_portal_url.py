#!/usr/bin/env python3
"""Build the Microsoft Foundry portal URL for an agent.

Reads a JSON object from stdin (Terraform `external` data source query) with:
  subscription_id, resource_group, account, project, agent
and prints {"url": "..."}. The portal encodes the subscription ID as the
base64url of its raw GUID bytes.
"""
import base64
import json
import sys

q = json.load(sys.stdin)

encoded_sub = (
    base64.urlsafe_b64encode(bytes.fromhex(q["subscription_id"].replace("-", "")))
    .decode()
    .rstrip("=")
)

url = (
    "https://ai.azure.com/nextgen/r/"
    f"{encoded_sub},{q['resource_group']},,{q['account']},{q['project']}"
    f"/build/agents/{q['agent']}/build"
)

print(json.dumps({"url": url}))
