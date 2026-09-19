# OpenConnector on an Azure VM

This repository deploys [oomol-lab/open-connector](https://github.com/oomol-lab/open-connector)
to one isolated, dual-stack Ubuntu VM. The VM runs the OpenConnector gateway
(image pinned to the `v1.6.1` release digest) and Caddy in Docker Compose.
OpenConnector uses its built-in SQLite storage on the VM disk; only HTTP/HTTPS
and operator SSH are allowed through the Azure NSG.

The deployment follows the same shape as the organization's Nango and Coturn
VMs:

- `infra/bicep/main.bicep` creates the VNet, dual-stack subnet, Standard static
  IPv4/IPv6 addresses, NIC, NSG, and VM.
- `infra/bicep/cloud-init.yml` installs Docker Compose, writes the protected
  runtime configuration, and enables the systemd service.
- `infra/docker-compose.yml` runs the connector and Caddy with persistent
  VM-disk data.
- `scripts/Deploy-OpenConnector.ps1` validates the deployment, saves a what-if,
  applies only with `-Apply -Confirm`, runs remote health checks, and prints
  the exact DNS records and addresses.

Caddy is the Certbot equivalent here: it obtains and renews the trusted
ACME/TLS certificate automatically. DNS must point at both public addresses
before the certificate can be issued.

## Public name

OpenConnector needs exactly one public hostname, unlike Nango's two: the API,
Web Console, `/docs`, `/mcp`, and every OAuth redirect callback are served from
a single origin configured through `OOMOL_CONNECT_ORIGIN`.

The default is:

- `connector.marketcanopy.com` — OpenConnector API, Web Console, and OAuth
  callbacks.

Create these records at the DNS provider after the apply step:

```text
connector        A       <reported-public-ipv4>
connector        AAAA    <reported-public-ipv6>
```

Keep TCP 80 open so Caddy can complete ACME HTTP-01 validation; Caddy then
serves the application on HTTPS and renews without operator intervention.

## Values required from the operator

Before applying, provide:

1. Azure subscription ID and the existing resource group.
2. Azure region, for example `westus3` (same region as the Nango VM).
3. An SSH public key and the operator's current public IPv4 CIDR, usually
   `x.x.x.x/32`. SSH is not opened to the whole Internet.
4. The public IPv6 prefix allocated for this VNet and its subnet prefix. These
   are subscription/network-specific and must not overlap the existing Coturn,
   Nango (`10.252.0.0/16`, `2404:f800:8000:124::/63`), or other VNet prefixes.
   The script intentionally requires them.
5. Confirmation of the default hostname, or a replacement for it.
6. An email address for ACME certificate notices.
7. Agreement on the pinned container images. The script currently pins the
   `ghcr.io/oomol-lab/open-connector` digest corresponding to release
   `v1.6.1`; Caddy is pinned by digest in `infra/docker-compose.yml`. Change
   any image only after testing the replacement.

The script generates and stores the credential-encryption key, the Web Console
admin token, and the runtime API token in a Windows ACL-protected file under
`.artifacts\<region>\openconnector-secrets.json`. Back those values up in the
company password vault. In particular, do not rotate
`OOMOL_CONNECT_ENCRYPTION_KEY` after provider connections exist without a
documented key-rotation migration (`runtime:data rotate-key`): it protects
stored OAuth credentials.

## Plan and apply

Run from PowerShell in this repository:

```powershell
.\scripts\Deploy-OpenConnector.ps1 `
  -SubscriptionId 00000000-0000-0000-0000-000000000000 `
  -Region westus3 `
  -ResourceGroup us-west `
  -SshPublicKeyPath $env:USERPROFILE\.ssh\id_ed25519.pub `
  -SshSourceCidr 203.0.113.10/32 `
  -VnetIpv6AddressPrefix 2404:f800:8000:126::/63 `
  -SubnetIpv6AddressPrefix 2404:f800:8000:126::/64
```

Review `.artifacts\westus3\deployment.whatif.json`. Then apply with the same
arguments plus:

```powershell
-Apply -Confirm
```

The script is safe to rerun with the same secret file. Existing VM
`customData` is preserved; the script reconciles the Compose environment,
Caddyfile, and image through Azure Run Command instead.

## OpenConnector configuration after infrastructure

The following are intentionally not hard-coded into the VM rollout because
they are product/integration configuration rather than Azure infrastructure:

- Provider OAuth client IDs and secrets registered in each provider's
  developer console. Redirect/callback URLs are derived from
  `OOMOL_CONNECT_ORIGIN`, so use `https://connector.marketcanopy.com/...` as
  shown by the console for each provider.
- Runtime tokens and scopes for the agents that call the gateway over
  `/v1` and `/mcp`; the bootstrap `OOMOL_CONNECT_RUNTIME_TOKEN` from the
  secrets file is only the starting point.
- Optional PostgreSQL 15+ (`OOMOL_CONNECT_DATABASE_URL`) and S3-compatible
  transit storage if the single-VM SQLite footprint becomes the limit.

These items cannot be completed solely by the Azure rollout script. They
require the OpenConnector Web Console and, for OAuth, the third-party
provider's developer console. The VM-level values that cannot be safely
supplied from the console are the encryption key, public origin, image
version, SSH/network policy, DNS, and TLS configuration; the script handles
those.

## Operational notes

The initial deployment is intentionally a single VM with SQLite on the local
disk. It is appropriate for evaluation and light production use only if the
VM disk backup strategy is accepted. For higher availability, move storage to
PostgreSQL 15+ (the image exposes a `migrate` subcommand for explicit
migrations) and use the upstream Helm chart with its Ingress, autoscaling,
and NetworkPolicy toggles.
