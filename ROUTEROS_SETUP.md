# Secure RouterOS WireGuard Setup

This guide shows one secure starting point for a RouterOS 7 WireGuard server that can be managed by WireRoute for macOS and used by WireRoute clients. It is an example, not a script to paste into an unknown router.

Review the existing interface lists, addresses, routing, firewall, NAT, services, certificates, and users before making changes. Rule order matters. Work from a trusted management connection, use RouterOS Safe Mode when practical, keep a second recovery path open, and make a protected backup according to your organization's policy.

> **Secrets:** Never commit or share a WireGuard private key, preshared key, RouterOS password, certificate private key, recovery export, or QR code. The client private key should be generated and retained on the client. WireRoute can store a managed client private key in Apple Keychain.

## Example plan

Every value below is documentation-only. Replace it with values that do not overlap an existing LAN, VPN, peer, or routed network.

| Purpose | Example value |
| --- | --- |
| WAN interface list | `WAN` |
| Trusted management Mac | `192.168.88.10/32` |
| Protected LAN | `192.168.88.0/24` |
| WireGuard interface | `wg-remote` |
| WireGuard subnet | `10.200.0.0/24` |
| Router tunnel address | `10.200.0.1/24` |
| First client address | `10.200.0.2/32` |
| WireGuard UDP port | `51820` |
| Public endpoint | `vpn.example.net:51820` |
| Router management name | `router.example.net` |

The public endpoint must resolve to the router's public address. If another gateway performs NAT in front of RouterOS, forward only UDP port `51820` to the RouterOS device. Do not expose RouterOS HTTPS to the internet.

## 1. Inspect the router first

These commands are read-only:

```routeros
/system resource print
/system package print
/interface list member print detail
/ip address print detail
/ip route print detail
/ip firewall filter print stats detail
/ip firewall nat print stats detail
/ip service print detail
/certificate print detail
/user group print detail
/user print detail
/interface wireguard print detail
/interface wireguard peers print detail
```

Confirm that `WAN` contains the real internet-facing interface or interfaces. Do not create duplicate established/related, invalid-drop, final-drop, or masquerade rules if the router already has suitable rules.

## 2. Create the WireGuard interface

RouterOS generates the interface key pair when `private-key` is omitted:

```routeros
/interface wireguard
add name=wg-remote listen-port=51820 mtu=1420 comment="WireRoute remote access"

/ip address
add address=10.200.0.1/24 interface=wg-remote comment="WireRoute tunnel subnet"

/interface wireguard print detail where name="wg-remote"
```

Copy only the interface `public-key` into the client configuration. The RouterOS interface private key stays on the router.

## 3. Add a client peer

Generate the client key pair in WireRoute, then add only its public key to RouterOS:

```routeros
/interface wireguard peers
add interface=wg-remote name="phone-01" \
    public-key="<CLIENT_PUBLIC_KEY>" \
    allowed-address=10.200.0.2/32 \
    responder=yes \
    comment="WireRoute phone-01"
```

Use a unique `/32` for every IPv4 client. Peer `allowed-address` values may not overlap on the same WireGuard interface. On this road-warrior server, a peer normally contains only addresses owned by that client; do not put the protected LAN or `0.0.0.0/0` in the RouterOS peer entry.

`responder=yes` marks RouterOS as the responding side and is available in current RouterOS 7 releases. Omit it on an older release that does not support the property.

## 4. Permit the WireGuard handshake

The UDP accept rule belongs in the IPv4 `input` chain after the early established/related accept and invalid drop, but before the final WAN/input drop:

```routeros
/ip firewall filter
add chain=input action=accept protocol=udp dst-port=51820 \
    in-interface-list=WAN \
    comment="WireRoute: allow WireGuard handshake"
```

Move the new rule to the correct position for the router's existing policy, then print the chain again to verify the order. Do not use a rule number copied from this guide; RouterOS rule numbers are local and can change.

If the client has a fixed public source address, adding `src-address=<CLIENT_PUBLIC_IP>/32` reduces exposure further. Mobile clients usually do not have a stable source address, so the public UDP listen port must remain reachable while cryptographic authentication controls tunnel admission.

## 5. Permit only intended forwarded traffic

Keep the WireGuard interface out of a broad trusted `LAN` interface list. Narrow rules make the permitted destinations visible.

Create a destination list for networks that Split Tunnel clients may reach:

```routeros
/ip firewall address-list
add list=wireroute-protected-lans address=192.168.88.0/24 \
    comment="WireRoute: protected LAN"
```

Add the following rules after the forward chain's established/related accept and invalid drop, but before broad forward drops. The final WireRoute rule denies any new traffic not explicitly permitted:

```routeros
/ip firewall filter
add chain=forward action=accept in-interface=wg-remote \
    src-address=10.200.0.0/24 dst-address-list=wireroute-protected-lans \
    comment="WireRoute: allow Split Tunnel destinations"

add chain=forward action=accept in-interface=wg-remote \
    src-address=10.200.0.0/24 out-interface-list=WAN \
    comment="WireRoute: allow Full Tunnel internet"

add chain=forward action=drop in-interface=wg-remote \
    src-address=10.200.0.0/24 \
    comment="WireRoute: drop other client forwarding"
```

If Full Tunnel must not be available, omit the WAN forward rule. Add additional protected subnets to `wireroute-protected-lans` only after reviewing their security boundary. Return traffic is handled by the established/related rule.

For Full Tunnel IPv4 internet access, first check whether an existing source-NAT rule already masquerades traffic leaving the WAN. If it does not, add one source-specific rule:

```routeros
/ip firewall nat
add chain=srcnat action=masquerade src-address=10.200.0.0/24 \
    out-interface-list=WAN \
    comment="WireRoute: Full Tunnel IPv4 NAT"
```

Do not add duplicate masquerade rules. NAT is not required merely to reach correctly routed internal networks.

## 6. Configure the client

A Split Tunnel profile based on the example plan is:

```ini
[Interface]
PrivateKey = <CLIENT_PRIVATE_KEY_CREATED_ON_THIS_DEVICE>
Address = 10.200.0.2/32
DNS = <REACHABLE_DNS_SERVER>

[Peer]
PublicKey = <ROUTER_WIREGUARD_PUBLIC_KEY>
Endpoint = vpn.example.net:51820
AllowedIPs = 192.168.88.0/24, 10.200.0.0/24
PersistentKeepalive = 25
```

WireRoute preserves those specific routes for Split mode. Its Full Tunnel control changes the effective client routes to the supported default route; it does not change the RouterOS peer's client `/32`. A keepalive of 25 seconds is useful for a phone behind NAT.

Use a DNS server reachable through one of the configured routes. If the router itself must answer DNS for VPN clients, explicitly allow TCP and UDP port 53 from `10.200.0.0/24` in the input chain and ensure DNS requests from `WAN` remain blocked. Do not enable a publicly reachable recursive resolver.

### IPv6

Do not add `::/0` until the router has a deliberate IPv6 tunnel prefix, IPv6 forwarding policy, and IPv6 firewall rules. When a profile has no supported IPv6 path, WireRoute Full mode blocks IPv6 rather than leaking it outside the tunnel. NAT66 is not part of this example.

## 7. Secure RouterOS REST access for WireRoute for macOS

WireRoute uses RouterOS REST over HTTPS at `/rest`. This requires `www-ssl`; it does **not** require the separate `api-ssl` service on TCP 8729. Keep `www` and the plaintext API disabled. Disable `api-ssl` too unless a different trusted tool specifically needs it.

### Use a dedicated account

Do not give WireRoute the built-in `admin` account. RouterOS permissions are not resource-level RBAC: the `write` policy can change more than WireGuard peers. Treat this credential as privileged even when it has a small custom policy set.

The following account can read discovery data and create, replace, or remove peers through REST, but cannot manage users, expose sensitive values, reboot, sniff, use WinBox, or use the console API:

```routeros
/user group
add name=wireroute-rest policy=read,write,rest-api

/user
add name=wireroute group=wireroute-rest \
    address=192.168.88.10/32 \
    password="<LONG_RANDOM_UNIQUE_PASSWORD>"
```

Generate the password with a trusted password manager and enter it directly on the router and Mac. Do not save it in a script, terminal transcript, issue, or repository. If the managing Mac uses DHCP, reserve its address or use a narrowly scoped management subnet instead of an unstable `/32`.

### Assign a server certificate

Prefer a certificate issued by an organizational CA or a publicly trusted certificate whose subject alternative name matches the exact DNS name used by WireRoute. For a private-address deployment, a RouterOS-local CA can be used. Confirm the router's clock first.

This example creates an ECC CA and a server-only certificate for both the DNS name and the management IP:

```routeros
/certificate
add name=wireroute-ca common-name="WireRoute RouterOS CA" \
    key-size=secp384r1 digest-algorithm=sha384 days-valid=3650 \
    key-usage=key-cert-sign,crl-sign
sign wireroute-ca

add name=wireroute-rest-cert common-name=router.example.net \
    subject-alt-name=DNS:router.example.net,IP:192.168.88.1 \
    key-size=secp384r1 digest-algorithm=sha384 days-valid=825 \
    key-usage=tls-server
sign wireroute-rest-cert ca=wireroute-ca

/certificate print detail where name~"wireroute"
```

Record the leaf certificate's SHA-256 fingerprint over a separate trusted administration path. WireRoute shows the presented certificate before accepting a self-signed deployment and pins the exact leaf certificate for that router host and port. Compare the displayed fingerprint with the separately verified RouterOS value. Do not approve an unexpected changed-certificate warning; verify whether the router certificate was intentionally renewed or replaced first.

### Restrict the service and firewall

Configure HTTPS for the single management host:

```routeros
/ip service
set www disabled=yes
set api disabled=yes
set api-ssl disabled=yes
set www-ssl disabled=no port=443 certificate=wireroute-rest-cert \
    tls-version=only-1.2 address=192.168.88.10/32

/ip service print detail where name~"www|api"
```

The service `address` restriction denies application access but does not drop packets at the network layer. Add a firewall boundary as well:

```routeros
/ip firewall address-list
add list=wireroute-admin address=192.168.88.10/32 \
    comment="WireRoute: approved management Mac"

/ip firewall filter
add chain=input action=accept protocol=tcp dst-port=443 \
    src-address-list=wireroute-admin \
    comment="WireRoute: allow RouterOS HTTPS from approved sources"

add chain=input action=drop protocol=tcp dst-port=443 \
    comment="WireRoute: drop RouterOS HTTPS from other sources"
```

Place both HTTPS rules after established/related and invalid handling, before any broad LAN-management accept rule, and before the final input drop. Keep the allow immediately above the drop. The drop rule reserves TCP 443 for RouterOS management; review the design first if the router also hosts another HTTPS or reverse-proxy service.

If WireRoute management must work from several trusted devices, add their individual `/32` addresses to `wireroute-admin` and to the `www-ssl` service address list. Do not use `0.0.0.0/0`. Remote peer traffic does not need RouterOS REST access to use the VPN.

## 8. Rule-order checklist

A secure existing firewall may contain additional policy, but the relative order should be:

### Input chain

1. Accept established, related, and optionally untracked traffic.
2. Drop invalid traffic.
3. Allow required control traffic such as carefully scoped ICMP.
4. Allow UDP `51820` from `WAN` for the WireGuard handshake.
5. Allow TCP `443` from `wireroute-admin`.
6. Drop TCP `443` from every other source.
7. Other narrowly scoped management rules.
8. Final input/WAN drop.

### Forward chain

1. FastTrack if the existing design uses it.
2. Accept established, related, and optionally untracked traffic.
3. Drop invalid traffic.
4. Allow WireRoute clients to approved Split Tunnel destinations.
5. Optionally allow WireRoute clients to `WAN` for Full Tunnel.
6. Drop other traffic entering from `wg-remote`.
7. Existing broader forward policy and final drops.

Never add an accept rule below a rule that already drops the same packet. Print rule counters after testing to prove that the intended rules—not a broader rule—are matching.

## 9. Validate the complete path

Check RouterOS state without displaying private keys in a public transcript:

```routeros
/interface wireguard print detail where name="wg-remote"
/interface wireguard peers print detail where interface="wg-remote"
/ip firewall filter print stats detail where comment~"WireRoute"
/ip firewall nat print stats detail where comment~"WireRoute"
/ip service print detail where name="www-ssl"
/user active print where name="wireroute"
```

Then verify each behavior from the actual client and from an unapproved source:

- The peer reports a recent handshake and increasing RX/TX counters.
- Split mode reaches only the intended protected networks and DNS server.
- Full mode reaches the internet through the expected public egress address.
- DNS resolution works without falling back outside the tunnel.
- TCP 443 reaches RouterOS only from an approved management address.
- Plain HTTP, TCP 8728, and TCP 8729 are not reachable unless intentionally required.
- A handshake alone is not considered success; routing, firewall, NAT, and DNS must also pass.

## 10. Roll back safely

If a new rule causes a problem, disable the exact rule by its unique comment first instead of deleting it. Confirm every `find` result before changing it:

```routeros
/ip firewall filter print where comment~"WireRoute"
/ip firewall nat print where comment~"WireRoute"
/interface wireguard peers print detail where interface="wg-remote"
```

Restore connectivity from the trusted recovery session, then review the disabled rule. Do not remove a certificate authority, user, interface, address, or NAT rule until dependencies are understood. RouterOS certificate removal can also remove certificates issued by that CA.

## Official RouterOS references

- [WireGuard](https://manual.mikrotik.com/docs/virtual-private-networks/wireguard/)
- [REST API](https://manual.mikrotik.com/docs/developer-guides/rest-api/)
- [Services](https://manual.mikrotik.com/docs/system-information-and-utilities/services/)
- [User management and policies](https://manual.mikrotik.com/docs/authentication-authorization-accounting/user/)
- [Building an advanced firewall](https://manual.mikrotik.com/docs/firewall-and-quality-of-service/user-guides/building-advanced-firewall/)
- [Certificates](https://manual.mikrotik.com/docs/authentication-authorization-accounting/certificates/)

RouterOS evolves. Check the documentation for the installed RouterOS version before applying a property introduced in a newer release.
