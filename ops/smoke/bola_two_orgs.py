#!/usr/bin/env python3
#
# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.
#
"""Two real organizations, real logins, plain HTTP: can one see or change the other's data?

OWASP API1 (BOLA) check from the outside, against a running stack. It registers
two brand-new organizations (A and B) the way a customer would, invites two
managers into A, creates contracts, values and a document, then tries every
cross-organization and cross-manager access it can think of and prints one
PASS/FAIL line per check. Exit code 0 only if every check passes.

Needs the backend in the dev profile (its DummyEmailService logs the
registration code, which this script reads with `docker logs`). Never point it
at production: it creates organizations and depends on dev-only email logging.

    python3 ops/smoke/bola_two_orgs.py                       # local stack
    API_BASE=http://127.0.0.1:8090/api/v1 BACKEND_CONTAINER=bcm-backend python3 ops/smoke/bola_two_orgs.py

Standard library only; safe to run repeatedly (every run uses fresh names).
"""

import base64
import hashlib
import hmac
import json
import struct
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

API = os.environ.get("API_BASE", "http://127.0.0.1:8090/api/v1").rstrip("/")
BACKEND_CONTAINER = os.environ.get("BACKEND_CONTAINER", "bcm-backend")
TERMS_VERSION = os.environ.get("TERMS_VERSION", "2026-10-28")
PASSWORD = "Bola-Smoke-2026!x"
RUN = uuid.uuid4().hex[:8]

results = []


# ── HTTP ────────────────────────────────────────────────────────────────────

def call(method, path, token=None, body=None, files=None):
    """Returns (status, parsed JSON or text). Never raises on HTTP errors."""
    headers = {}
    data = None
    if token:
        headers["Authorization"] = "Bearer " + token
    if files is not None:
        boundary = "bola" + uuid.uuid4().hex
        name, filename, content, ctype = files
        data = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"; filename=\"{filename}\"\r\n"
                f"Content-Type: {ctype}\r\n\r\n").encode() + content + f"\r\n--{boundary}--\r\n".encode()
        headers["Content-Type"] = "multipart/form-data; boundary=" + boundary
    elif body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(API + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            status, raw = response.status, response.read()
    except urllib.error.HTTPError as error:
        status, raw = error.code, error.read()
    text = raw.decode("utf-8", errors="replace")
    try:
        return status, json.loads(text) if text else None
    except ValueError:
        return status, text


def must(method, path, token=None, body=None, files=None, expect=(200, 201, 202)):
    """Setup call that has to succeed; aborts the run otherwise.

    A 429 is the auth rate limiter doing its job (registration, invites and
    logins share a per-minute budget): wait for the window and retry.
    """
    status, payload = call(method, path, token, body, files)
    for _ in range(3):
        if status != 429:
            break
        print(f"  rate limited on {path}, waiting 61s")
        time.sleep(61)
        status, payload = call(method, path, token, body, files)
    if status not in expect:
        sys.exit(f"SETUP FAILED: {method} {path} -> {status} {payload}")
    return payload


def check(name, ok, detail=""):
    results.append(ok)
    print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else f"  ({detail})"))


def expect_status(name, expected, method, path, token=None, body=None):
    status, payload = call(method, path, token, body)
    check(name, status == expected, f"got {status} {str(payload)[:160]}")
    return payload


# ── Setup through the public API ───────────────────────────────────────────

def registration_code(email):
    pattern = re.compile(r"registration code email sent to: " + re.escape(email) + r" with code: (\d{6})")
    for _ in range(20):
        logs = subprocess.run(["docker", "logs", "--since", "10m", BACKEND_CONTAINER],
                              capture_output=True, text=True, check=False)
        found = pattern.findall(logs.stdout + logs.stderr)
        if found:
            return found[-1]
        time.sleep(1)
    sys.exit(f"SETUP FAILED: no registration code for {email} in the {BACKEND_CONTAINER} log")


def register(label):
    email = f"bola-{RUN}-{label}@example.com"
    started = must("POST", "/organizations/register", body={
        "organizationName": f"BOLA {RUN} {label.upper()}",
        "adminUsername": f"bola{RUN}{label}",
        "adminPassword": PASSWORD,
        "adminEmail": email,
        "adminFirstName": "Bola",
        "adminLastName": label.upper(),
        "termsVersion": TERMS_VERSION,
        "termsAccepted": True,
        "professionalUse": True,
        "onerousClausesApproved": True,
    })
    confirmed = must("POST", "/organizations/register/confirm",
                     body={"registrationId": started["registrationId"], "code": registration_code(email)})
    # A new admin gets no session until 2FA is set up (backend TwoFactorPolicy).
    if not confirmed.get("mfaSetupRequired"):
        sys.exit(f"SETUP FAILED: a new admin got a session without 2FA: {confirmed}")
    setup_token = confirmed["setupToken"]
    secret = must("POST", "/auth/2fa/enroll/setup", body={"setupToken": setup_token})["secret"]
    enrolled = must("POST", "/auth/2fa/enroll/confirm", body={"setupToken": setup_token, "code": totp(secret)})
    return enrolled["token"]


def totp(secret_base32):
    """The current RFC 6238 code (SHA-1, 6 digits, 30 s), as an authenticator app shows it."""
    key = base64.b32decode(secret_base32 + "=" * (-len(secret_base32) % 8), casefold=True)
    digest = hmac.new(key, struct.pack(">Q", int(time.time()) // 30), hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    return "%06d" % ((struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF) % 1_000_000)


def login(username):
    payload = must("POST", "/auth/login", body={"username": username, "password": PASSWORD})
    if not payload.get("token"):
        sys.exit(f"SETUP FAILED: login for {username} returned no token: {payload}")
    return payload["token"]


def seed(token, label):
    """One area, counterparty, financial type and manager; returns their ids."""
    area = must("POST", "/business-areas", token, {"name": f"Area {RUN} {label}"})
    counterparty = must("POST", "/counterparties", token, {"name": f"Cliente {RUN} {label}", "type": "CUSTOMER"})
    ftype = must("POST", "/financial-types", token,
                 {"name": f"Tipo {RUN} {label}", "description": "bola", "category": "REVENUE"})
    return {"area": area["id"], "counterparty": counterparty["id"], "type": ftype["id"]}


def manager(token, label):
    created = must("POST", "/managers", token, {"firstName": "Resp", "lastName": f"{label} {RUN}",
                                               "email": f"bola-{RUN}-{label}-mgr@example.com"})
    username = f"bola{RUN}{label}m"
    invite = must("POST", "/users/invite", token,
                  {"username": username, "role": "MANAGER", "managerId": created["id"]})
    invite_token = invite["inviteLink"].split("token=")[1]
    must("POST", "/auth/complete-invite", body={"token": invite_token, "password": PASSWORD}, expect=(200, 201, 204))
    return created["id"], login(username)


def contract(token, base, manager_id, label):
    number = f"BOLA-{RUN}-{label}"
    created = must("POST", "/contracts", token, {
        "counterpartyId": base["counterparty"], "contractNumber": number, "status": "ACTIVE",
        "startDate": "2026-01-01", "endDate": "2027-12-31", "areaId": base["area"], "managerId": manager_id,
    })
    value = must("POST", "/financial-values", token, {
        "month": 1, "year": 2026, "financialAmount": 1000, "contractId": created["id"],
        "financialTypeId": base["type"], "businessAreaId": base["area"],
    })
    return {"id": created["id"], "number": number, "value": value["id"]}


# ── The checks ─────────────────────────────────────────────────────────────

def main():
    print(f"BOLA two-organization check against {API} (run {RUN})")
    status, _ = call("GET", "/actuator/health")
    if status != 200:
        sys.exit(f"SETUP FAILED: backend not healthy at {API} ({status})")

    admin_a, admin_b = register("a"), register("b")
    base_a, base_b = seed(admin_a, "a"), seed(admin_b, "b")
    mgr1, mgr1_token = manager(admin_a, "a1")
    mgr2, _ = manager(admin_a, "a2")
    mgr_b, _ = manager(admin_b, "b1")
    a1 = contract(admin_a, base_a, mgr1, "A1")
    a2 = contract(admin_a, base_a, mgr2, "A2")
    b1 = contract(admin_b, base_b, mgr_b, "B1")
    document = must("POST", f"/contracts/{a2['id']}/documents", admin_a,
                    files=("file", "bola.pdf", b"%PDF-1.4\n%bola\n", "application/pdf"))
    print("setup: 2 organizations, 3 managers, 3 contracts, 1 document\n")

    b_contract_before = must("GET", f"/contracts/{b1['id']}", admin_b)
    b_value_before = must("GET", f"/financial-values/{b1['value']}", admin_b)

    # 1. Organization A's admin against organization B's objects: 404, like a missing id.
    for path in (f"/contracts/{b1['id']}", f"/financial-values/{b1['value']}",
                 f"/business-areas/{base_b['area']}", f"/counterparties/{base_b['counterparty']}",
                 f"/financial-types/{base_b['type']}", f"/managers/{mgr_b}",
                 f"/financial-values/by-contract/{b1['id']}", f"/contract-history/contract/{b1['id']}",
                 f"/contracts/{b1['id']}/collaborators", f"/contracts/{b1['id']}/documents",
                 f"/contracts/{b1['id']}/invoices", f"/contracts/{b1['id']}/workflow/events"):
        expect_status(f"A admin reads B {path}", 404, "GET", path, admin_a)
    expect_status("A admin updates B's contract", 404, "PUT", f"/contracts/{b1['id']}", admin_a, {
        "counterpartyId": base_a["counterparty"], "contractNumber": "HIJACKED", "status": "ACTIVE",
        "startDate": "2026-01-01", "endDate": "2027-12-31", "areaId": base_a["area"]})
    expect_status("A admin updates B's financial value", 404, "PUT", f"/financial-values/{b1['value']}", admin_a, {
        "month": 2, "year": 2026, "financialAmount": 1, "contractId": a1["id"],
        "financialTypeId": base_a["type"], "businessAreaId": base_a["area"]})
    expect_status("A admin deletes B's financial value", 404, "DELETE", f"/financial-values/{b1['value']}", admin_a)
    expect_status("A admin deletes B's contract", 404, "DELETE", f"/contracts/{b1['id']}", admin_a)
    check("B's contract unchanged after A's attempts",
          must("GET", f"/contracts/{b1['id']}", admin_b) == b_contract_before)
    check("B's financial value unchanged after A's attempts",
          must("GET", f"/financial-values/{b1['value']}", admin_b) == b_value_before)

    # 2. References to B inside A's own write bodies.
    expect_status("A creates a contract with B's counterparty", 404, "POST", "/contracts", admin_a, {
        "counterpartyId": base_b["counterparty"], "contractNumber": f"BOLA-{RUN}-X", "status": "ACTIVE",
        "startDate": "2026-01-01", "endDate": "2027-12-31", "areaId": base_a["area"]})
    status, _ = call("PATCH", f"/contracts/{a1['id']}/assign-manager", admin_a, {"managerId": mgr_b})
    check("A assigns B's manager to its contract", status in (400, 404), f"got {status}")
    status, _ = call("PATCH", f"/contracts/{a1['id']}/collaborators", admin_a, {"managerIds": [mgr_b]})
    check("A adds B's manager as collaborator", status in (400, 404), f"got {status}")

    # 3. A client-supplied id on create never overwrites B's row.
    status, created = call("POST", "/business-areas", admin_a, {"id": base_b["area"], "name": f"Overwrite {RUN}"})
    check("create with B's area id gets a fresh id",
          status == 201 and created.get("id") != base_b["area"], f"got {status} {created}")
    area_b = must("GET", f"/business-areas/{base_b['area']}", admin_b)
    check("B's area unchanged", area_b.get("name") == f"Area {RUN} b", f"got {area_b}")

    # 4. A plain manager against a colleague's contract in the same organization: 403.
    expect_status("manager reads own contract", 200, "GET", f"/contracts/{a1['id']}", mgr1_token)
    for path in (f"/contracts/{a2['id']}", f"/financial-values/by-contract/{a2['id']}",
                 f"/financial-values/{a2['value']}", f"/contracts/{a2['id']}/documents",
                 f"/contract-history/contract/{a2['id']}"):
        expect_status(f"manager reads colleague's {path}", 403, "GET", path, mgr1_token)
    expect_status("manager reads B's contract", 404, "GET", f"/contracts/{b1['id']}", mgr1_token)

    # 5. A child addressed through the wrong parent (same organization): 404.
    expect_status("A2's document under A1", 404, "GET",
                  f"/contracts/{a1['id']}/documents/{document['id']}/versions", admin_a)
    expect_status("A2's document under its own contract", 200, "GET",
                  f"/contracts/{a2['id']}/documents/{document['id']}/versions", admin_a)

    # 6. Lists and aggregates stay inside the organization.
    for path in ("/contracts", "/contracts/search?q=BOLA", "/financial-values", "/counterparties",
                 "/business-areas", "/managers", "/users", "/contract-history"):
        status, payload = call("GET", path, admin_a)
        text = json.dumps(payload)
        check(f"A's {path} holds nothing of B", status == 200 and b1["number"] not in text
              and f"Cliente {RUN} b" not in text and f"bola{RUN}bm" not in text, f"got {status}")
    status, payload = call("GET", "/contracts/search?q=BOLA", mgr1_token)
    text = json.dumps(payload)
    check("manager's search holds only own contracts", status == 200 and a1["number"] in text
          and a2["number"] not in text and b1["number"] not in text, f"got {status}")
    stats = {p: must("GET", p, admin_a) for p in ("/contracts/stats", "/contracts/stats/by-area",
                                                  "/contracts/stats/invoicing-summary", "/home/attention")}
    contract(admin_b, base_b, mgr_b, "B2")
    for path, before in stats.items():
        check(f"A's {path} unchanged by B's new contract", must("GET", path, admin_a) == before)

    # 7. No token, no data.
    expect_status("no token on a contract", 401, "GET", f"/contracts/{a1['id']}")

    failed = results.count(False)
    print(f"\n{len(results) - failed}/{len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
