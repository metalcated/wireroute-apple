# WireRoute Support

WireRoute is a free, open-source WireGuard client for iOS and macOS. It does not provide a VPN subscription, hosted VPN service, or RouterOS service. You need access to your own compatible WireGuard endpoint and, for the optional macOS peer-management workflow, your own RouterOS system.

## Get Help

- Follow the [secure RouterOS WireGuard setup guide](ROUTEROS_SETUP.md) for a documentation-only example covering the VPN server, firewall, NAT, HTTPS REST access, and validation.
- Search the [existing issues](https://github.com/metalcated/wireroute-apple/issues) for a known problem.
- [Open a support request](https://github.com/metalcated/wireroute-apple/issues/new) for app issues, feedback, or feature requests.
- Contact the project maintainer through the [metalcated GitHub profile](https://github.com/metalcated).

When reporting a problem, include:

- WireRoute version and build number
- iOS or macOS version
- Device or Mac model
- Steps that reproduce the problem
- What you expected and what happened instead
- Sanitized log lines that are directly relevant

## Protect Your Secrets

GitHub issues are public. Never post or attach:

- WireGuard private keys or preshared keys
- RouterOS passwords or session credentials
- Complete tunnel configuration files or exports
- Unredacted certificates, recovery configurations, or QR codes
- Public endpoints, IP addresses, DNS names, usernames, or public keys that you consider sensitive

Public keys are not secret cryptographic material, but they can identify a deployment. Redact them when they are not needed to diagnose the issue.

For a suspected security vulnerability, follow the private-reporting guidance in [SECURITY.md](SECURITY.md) instead of opening a detailed public issue.

## License and Warranty

WireRoute is provided under the [MIT License](COPYING), without warranty. Support is community-based and response times are not guaranteed.
