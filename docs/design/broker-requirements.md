# OpenBake broker: requirements and design outline

*2026-11-15. Status: draft for review, nothing decided. Follows the sandbox experiment in
`sandbox/` (agent with no internet, nginx broker that injects the LLM key). Section 8 lists the
decisions needed before this becomes a design like [`phase1-design.md`](phase1-design.md).*

## 1. Summary

Every workspace started with `make up` gets a **broker**: the only network path out of the
workspace container. The broker allows or denies each outbound action, injects real credentials
so the workspace never holds them, redacts sensitive data, pauses risky actions for a human, and
writes an audit record for every decision.

It covers four traffic classes: LLM APIs, git and package registries, databases, and other
HTTP including MCP. It is inspired by [hoop](https://github.com/hoophq/hoop) but is a clean
implementation: hoop's masking core (`libhoop`) is closed, and hoop targets shared production
databases, where OpenBake targets a developer's own workspace.

## 2. Scope chosen (2026-11-15)

| Question | Answer |
|---|---|
| Traffic | LLM APIs; git and package registries; databases; any HTTP and MCP |
| Main risk | credential theft, data exfiltration and destructive actions, equally |
| Controls | allowlist + key injection; audit log; masking and redaction; block rules and approvals; each based on a published standard |
| Where | every `make up` workspace (local and `DOCKER_HOST=ssh://`), not `make host` machines |

## 3. Threat model

**Assets:** API keys and tokens (LLM, GitHub, registries, databases); source code and data in the
workspace; remote systems the workspace can change (repositories, databases, APIs).

**Adversary:** the agent process itself once it follows hostile instructions (prompt injection
from a web page, a dependency, an issue, a tool result), or a malicious package running in the
workspace. Both run as `user` inside the container with full control of it.

**Trust boundary:** the container is untrusted. The broker, its policy, its secrets and its log
are trusted and must be unreachable from the container except through the proxy ports.

**What a network broker cannot do (must be stated in the README):**

1. It does not stop prompt injection; it limits what a hijacked agent can reach and do.
2. The LLM API is itself an exfiltration path: anything the agent can read, it can put in a
   prompt. The broker can block known secrets and cap sizes, not judge meaning.
3. An allowlisted host that accepts writes is an exfiltration path (a GitHub repo, a package
   upload). Rules must be per method and path, not per host.
4. Tools that pin certificates break under TLS inspection; they get a tunnel without inspection
   or are denied.
5. It sees only network actions. Destructive local actions (`rm -rf ~/workspace`) are out of
   scope; the home volume and git are the recovery path.

## 4. Requirements

IDs are for review and tests. **M** = must for the first release, **S** = should, **L** = later.

### 4.1 Isolation and routing

| ID | Requirement | |
|---|---|---|
| R-NET-1 | The workspace container is attached only to an internal Docker network; the broker is the only container on both that network and an outbound one | M |
| R-NET-2 | Default deny: a destination not in the policy is refused and logged | M |
| R-NET-3 | The workspace has no external DNS; the broker resolves names, and refuses private, loopback, link-local and metadata addresses after resolution | M |
| R-NET-4 | Only HTTP(S), and the database listeners in policy, leave the workspace. SSH, raw TCP and UDP are refused | M |
| R-NET-5 | Broker down or policy invalid means no egress (fail closed) | M |
| R-NET-6 | The Docker socket is never mounted in a workspace | M |

### 4.2 Credentials

| ID | Requirement | |
|---|---|---|
| R-CRED-1 | Real credentials exist only in the broker's secret file; the workspace gets placeholders | M |
| R-CRED-2 | A credential is injected only for its own destination and only after the request passed policy | M |
| R-CRED-3 | Credentials never appear in the audit log, error messages or responses to the workspace | M |
| R-CRED-4 | Responses that echo an injected credential are redacted | S |
| R-CRED-5 | Short-lived, narrowly scoped tokens where the upstream supports them (GitHub App installation tokens, fine-grained PATs per repo) | S |

### 4.3 Policy and decisions

| ID | Requirement | |
|---|---|---|
| R-POL-1 | One declarative policy file per profile, in the repo, reviewed like code; a workspace can only narrow it | M |
| R-POL-2 | Five decisions, as in AARM: `allow`, `deny`, `modify` (inject, redact), `step_up` (human approval), `defer` (hold until a condition, with timeout) | M (`defer`: L) |
| R-POL-3 | Rules match on destination, method, path, protocol-specific fields (git ref and operation, MCP tool name, SQL statement class) and data labels | M |
| R-POL-4 | Deterministic rules run first and always win; any model-based scoring can only make a decision stricter | M |
| R-POL-5 | Three rule classes: forbidden (always deny), allowed with conditions, approval required | M |
| R-POL-6 | A denied request returns a clear, protocol-correct error with a reason and rule ID, so the agent can adapt | M |
| R-POL-7 | `make policy-check` validates the file and runs its test cases without starting a workspace | M |

### 4.4 Approvals

| ID | Requirement | |
|---|---|---|
| R-APP-1 | A `step_up` request is held; the operator sees destination, operation, a redacted summary and the rule, then approves or denies | M |
| R-APP-2 | No UI in the first release: `make approvals NAME=` lists, `make approve ID=` / `make deny ID=` decide | M |
| R-APP-3 | The approval channel is not reachable from the workspace network | M |
| R-APP-4 | No answer within the timeout means deny | M |
| R-APP-5 | An approval covers exactly one request (bound to its hash), never "all similar for 10 minutes" by default | M |
| R-APP-6 | Approval rules stay few and specific, to avoid approval fatigue; target fewer than 5 prompts per working day for the default profiles | S |

### 4.5 Masking and redaction

| ID | Requirement | |
|---|---|---|
| R-MASK-1 | Outbound: block or redact the workspace's own known secrets by exact match (the broker holds them, so there are no false positives) | M |
| R-MASK-2 | Outbound: detect high-confidence secret formats (private keys, cloud and provider key prefixes) and deny | M |
| R-MASK-3 | Inbound from databases: mask columns by name and type rules, and values by detectors (email, phone, IBAN, card number, national IDs) | with databases |
| R-MASK-4 | Masking methods are named and chosen per rule: redact, partial (keep last 4), hash with per-workspace salt (stable pseudonym), null | with databases |
| R-MASK-5 | Unlabelled data is treated as the most sensitive class | S |
| R-MASK-6 | No model-based PII detection in the first release; patterns and column rules only | - |

### 4.6 Audit

| ID | Requirement | |
|---|---|---|
| R-AUD-1 | One record per decision: time (UTC), workspace, profile, protocol, destination, operation, decision, rule ID, approver, sizes, duration, upstream status | M |
| R-AUD-2 | Bodies are not logged by default; a SHA-256 and size are. Optional body capture is redacted first | M |
| R-AUD-3 | JSON Lines on a volume the workspace cannot mount; each record carries the hash of the previous one (tamper evidence) | M |
| R-AUD-4 | `make audit NAME=` prints and filters; `make audit-verify` checks the chain | M |
| R-AUD-5 | Field names follow OpenTelemetry semantic conventions where one exists | S |
| R-AUD-6 | The sentinel test (design 6.5) also searches the audit log and broker output | M |

### 4.7 Per traffic class

| Class | First-release behaviour | Later |
|---|---|---|
| **LLM APIs** | named upstreams (Anthropic, OpenAI); key injection; streaming passthrough; known-secret check on request bodies; request and token counts logged | spend limits per workspace |
| **Git** | HTTPS only; token injection; allow by owner/repo; `git push` parsed for ref updates: force push and protected branches denied or `step_up`, deletes `step_up` | commit signing by the broker |
| **Registries** | read-only (GET/HEAD) to npm, PyPI, crates, apt mirrors, GitHub releases; publish endpoints denied | pull through a scanning mirror (design section 9, item 4) |
| **HTTP** | allowlist by host, method and path; everything else denied | |
| **MCP** | remote MCP servers over HTTP are allowlisted like any host; `tools/call` parsed and matched by tool name; tool annotations are untrusted input; tool definitions pinned by hash, a change needs approval | result scanning |
| **Databases** | PostgreSQL only: broker authenticates upstream with the real password; statements parsed; `DROP`/`TRUNCATE`/`DELETE` or `UPDATE` without `WHERE`/DDL are denied or `step_up`; result masking | MySQL; SQL Server only on demand |

### 4.8 Non-functional

| ID | Requirement | |
|---|---|---|
| R-NF-1 | Added latency below 10 ms per request at p95, excluding approvals; streaming is not buffered | M |
| R-NF-2 | One static binary in a minimal image, read-only root filesystem, no capabilities, non-root | M |
| R-NF-3 | Built and pinned under the supply-chain policy (lockfile, hashes, OSV gate); the broker image follows the same refresh and scan rules as workspace images | M |
| R-NF-4 | Docker stays the only prerequisite; all broker commands are `make` targets through the runner | M |
| R-NF-5 | Works on amd64 and arm64, on local and remote Docker endpoints | M |

## 5. Standards basis

How to read this: "verified" means checked against current sources on 2026-11-15; "from memory"
means the clause numbers must be re-checked before they are quoted outside this repo.

| Control | Primary basis | Supporting | What we take from it |
|---|---|---|---|
| **Overall shape** | **AARM** (Autonomous Action Runtime Management, CSAI Foundation; verified): intercept before execution, context, policy, five decisions, signed receipts, identity binding. The broker is its "protocol gateway" architecture | OWASP **Agent Control Standard** v0.1 (verified; preview, hook vocabulary only); NIST SP 800-207 PEP/PDP (from memory) | decision vocabulary (R-POL-2), rule classes (R-POL-5), requirement checklist R1-R6 as our conformance target |
| **Risk taxonomy** | OWASP **Top 10 for Agentic Applications 2026** (verified): goal hijack (ASI01), tool misuse (ASI02), identity and privilege abuse, supply chain, code execution | OWASP Top 10 for LLM Applications (2025 and 2026 editions are numbered differently; cite risks by name): prompt injection, sensitive information disclosure, excessive agency | each requirement in section 4 is tagged with the risk it reduces (to do in the design) |
| **Allowlist** | NIST SP 800-53 r5 **SC-7(5)** deny by default, allow by exception; **AC-4** information flow enforcement; **AC-6** least privilege (from memory) | CIS Controls v8 network controls; OWASP SSRF Prevention Cheat Sheet (from memory) | R-NET-2, R-NET-3, per-method and per-path rules |
| **Credential injection** | NIST SP 800-53 **IA-5** authenticator management; OWASP Secrets Management Cheat Sheet (from memory) | NIST AI Agent Standards Initiative and NCCoE agent identity project (verified; no final guidance yet): OAuth-based, short-lived, scoped | R-CRED-1 to R-CRED-5 |
| **Masking** | ISO/IEC 27001:2022 Annex A **8.11** data masking and **8.12** data leakage prevention (verified) | ISO/IEC 20889 de-identification techniques; NIST SP 800-188; GDPR Art. 4(5), 25, 32; PCI DSS 4.0 req. 3.4 for card numbers (from memory) | named techniques (R-MASK-4), minimum disclosure, pseudonym keys kept apart |
| **Block rules** | AARM action classification: forbidden, context-dependent deny, context-dependent allow (verified) | MCP specification: tool annotations (`readOnlyHint`, `destructiveHint`) are hints and untrusted; OWASP MCP Security Cheat Sheet (verified) | R-POL-5; MCP row in 4.7 |
| **Approvals** | NIST SP 800-53 **AC-3(2)** dual authorization, **AC-5** separation of duties (from memory) | MCP specification: a human should be able to deny tool invocations (verified); EU AI Act Art. 14 human oversight as a design reference only (OpenBake is not a high-risk system; those obligations now apply from December 2027) | R-APP-1 to R-APP-6 |
| **Audit** | ISO/IEC 27001:2022 Annex A **8.15** logging, **8.16** monitoring (verified); NIST SP 800-53 **AU-2, AU-3, AU-9, AU-10** (from memory) | NIST SP 800-92; OWASP Logging Cheat Sheet; OpenTelemetry semantic conventions; AARM tamper-evident receipts | R-AUD-1 to R-AUD-5 |

Not a basis: hoop's own rule format, and vendor "AI firewall" taxonomies.

## 6. Design outline

```text
                 inner network (internal: no route out)        outer network
┌──────────────┐        ┌───────────────────────────────────┐
│ ws-<name>    │  HTTP  │ ws-<name>-broker                  │
│ agent, tools ├───────►│ :8080 named upstreams (LLM)       ├──► api.anthropic.com …
│ HTTPS_PROXY  │ proxy  │ :8081 forward proxy (CONNECT)     ├──► github.com, registries, MCP
│ placeholders │  PG    │ :5432 PostgreSQL listener         ├──► database
└──────────────┘        │ policy · secrets · audit volume   │
                        └───────────────▲───────────────────┘
                                        │ admin socket (approvals, audit), host only
                                     make approvals / approve / audit
```

**Three ways in, by how much the broker must see:**

1. **Named upstream** (as the nginx broker today): the tool is pointed at the broker with a base
   URL (`ANTHROPIC_BASE_URL`). Plain HTTP inside the inner network, TLS from broker to upstream.
   Full inspection, no certificate authority needed. Preferred wherever a tool supports it.
2. **Forward proxy, tunnel only:** `HTTPS_PROXY` + CONNECT. The broker checks the host name
   against the allowlist and tunnels. No inspection, so no method or path rules and no injection.
   Only for read-only hosts where host-level control is enough.
3. **Forward proxy with TLS inspection:** for hosts that need method, path or body rules or
   credential injection (GitHub, registries with publish endpoints, MCP servers). Needs a
   per-workspace CA that the image trusts; the CA key stays in the broker.

**Template change (design 6.4):** two `docker_network` resources and one more
`docker_container` per workspace, same labels and state. The workspace loses its direct network.
**Secrets change (design 6.5):** the env file splits in two: workspace variables (placeholders,
`PASSWORD`) and broker secrets (real keys), the second mounted only into the broker.

**Policy sketch** (format is decision D3):

```yaml
upstreams:
  anthropic: { url: https://api.anthropic.com, inject: { header: x-api-key, secret: ANTHROPIC_API_KEY } }
rules:
  - id: llm
    match: { upstream: anthropic, path: /v1/** }
    decision: allow
    checks: [known_secrets, secret_formats]
  - id: git-read
    match: { host: github.com, repo: rkh0x7EA/openbake, git: fetch }
    decision: allow
  - id: git-force-push
    match: { host: github.com, git: push, force: true }
    decision: deny
  - id: git-push-main
    match: { host: github.com, git: push, ref: refs/heads/main }
    decision: step_up
  - id: npm-read
    match: { host: registry.npmjs.org, method: [GET, HEAD] }
    decision: allow
```

## 7. Phasing proposal

| Phase | Contents | Proves |
|---|---|---|
| **B1** | Broker replaces nginx: named upstreams for Anthropic and OpenAI, injection, default deny, audit log with hash chain, internal network in the template, `make audit` | isolation, credentials, audit, on every `make up` |
| **B2** | Forward proxy: tunnel allowlist, TLS inspection, registries read-only, git rules, known-secret and secret-format checks, `policy-check` | allowlist and block rules for the agent's daily work |
| **B3** | Approvals (`step_up`) with the make commands; MCP parsing and tool pinning | human oversight |
| **B4** | PostgreSQL listener: statement rules and result masking | hoop-equivalent database control |

B1 is close to what `sandbox/` already does and is the only phase that changes the phase 1
template, so it should be designed together with M6 (workspaces) and M7 (secrets).

## 8. Open decisions

| # | Decision | Options | Note |
|---|---|---|---|
| D0 | Separate product | (a) directory in this repo; (b) own repo and name (working name `opensidecar`), consumed by OpenBake as a pinned image | Raised 2026-11-15. For (b): sections 3-5 and the broker itself are independent of OpenBake (any container, CI job or laptop agent could use it); only the template and env-file changes in section 6 are OpenBake-specific. Against: a second repo to pin, release and scan before either has users. Middle path: develop in `broker/` here with no imports from the rest of the repo, split when B1 works |
| D1 | Build or adopt | (a) own Rust binary; (b) compose existing parts (Envoy or mitmproxy for HTTP, a Postgres proxy for B4); (c) adopt an existing agent gateway | Evaluate (b) and (c) for a day before committing: a custom TLS-inspecting proxy is security-critical code we then own. Candidates to check: agentgateway, mitmproxy, Envoy with an external authorizer, Stripe smokescreen (tunnel allowlist only), hoop's MIT gateway |
| D2 | If own binary: language and base | Rust with hyper + rustls (+ pgwire, sqlparser for B4); Go | Rust adds a toolchain to the supply-chain policy (cargo lockfile, vendoring or hashes, `cargo-deny`) |
| D3 | Policy language | small own YAML (sketch above); Rego (regorus); Cedar | Own YAML is easiest to read and test; Rego or Cedar give a known language at the cost of a dependency. ACS aims at portable policy files but is a preview |
| D4 | TLS inspection | per-workspace CA trusted in the image; or avoid inspection and use only named upstreams and tunnels | Without inspection there are no git or registry method rules and no injection for them |
| D5 | Is the broker optional | always on; on by default with `BROKER=0`; on only for the `agent` profile | "Every `make up` workspace" was chosen; devbox users may want an opt-out |
| D6 | Order against the MVP | after M6-M7; or B1 inside M6 | B1 changes the template and the env file, so doing it later means touching both twice |
| D7 | Approval channel | make commands only; plus a desktop notification; plus a web page | Phase 1 has no UI by design |
| D8 | LLM request content | pass through with secret checks only; or also redact personal data in prompts | Redacting prompts changes what the agent sees and can break tasks |

## 9. Sources

- AARM specification: <https://arxiv.org/abs/2602.09433>
- OWASP Top 10 for Agentic Applications 2026: <https://genai.owasp.org/resource/owasp-top-10-for-agentic-applications-for-2026/>
- OWASP Agent Control Standard: <https://genai.owasp.org/resource/agent-control-standard-acs/>
- OWASP MCP Security Cheat Sheet: <https://cheatsheetseries.owasp.org/cheatsheets/MCP_Security_Cheat_Sheet.html>
- CSA research note on agent standards in 2026: <https://labs.cloudsecurityalliance.org/research-rb/csa-research-note-ai-agent-standards-convergence-2026-202605/>
- NIST AI Agent Standards Initiative (overview): <https://www.pillsburylaw.com/en/news-and-insights/nist-ai-agent-standards.html>
- ISO/IEC 27002:2022 control 8.11: <https://www.isms.online/iso-27002/control-8-11-data-masking>
- EU AI Act dates after the Digital Omnibus: <https://www.dataprotectionreport.com/2026/07/the-eu-ai-act-when-does-it-become-enforceable-now/>
- hoop: <https://github.com/hoophq/hoop>
