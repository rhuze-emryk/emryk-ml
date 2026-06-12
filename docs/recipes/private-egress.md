# Private egress (VPN)

Earlier releases shipped a `:latest-private-ml` variant that baked the Mullvad
VPN daemon into the image. That was retired: embedding a single commercial VPN
vendor in every image works against the project principle of *no lock-in* — if
the vendor is acquired, changes policy, or its package repo moves, every image
carries that liability. So private egress is now something you **enable**, not
something we **embed**.

To be honest about the boundary: that same argument applies in principle to
Tailscale, which *is* embedded as the management plane. That is the image's one
deliberate vendor commitment — see "Remote management" in the README, including
the self-hosted [Headscale](https://github.com/juanfont/headscale) escape
hatch. Option A below leans further into Tailscale's commercial service (it's
a paid add-on on their SaaS control plane); Option B is the route that doesn't.
Pick with eyes open.

There are two routes. The first needs nothing installed on the host and is the
recommended one.

## Option A — Mullvad exit node via Tailscale (recommended)

Tailscale (already in this image as the management/access plane) offers
**Mullvad exit nodes** as a first-class feature. Your traffic egresses through
Mullvad, but **no Mullvad software runs on the workstation** — it rides the
Tailscale you already have. No new vendor is embedded in the image; you can turn
it off at any time with one command.

1. In the **Tailscale admin console**, enable **Mullvad** (it's a paid add-on —
   check current pricing/terms there; it's billed through Tailscale, you don't
   need a separate Mullvad account). This feature lives in Tailscale's
   commercial control plane: it is **not available on a self-hosted Headscale**
   tailnet — if you run Headscale, use Option B.
2. On the workstation (already joined to your tailnet via `tailscaled`):

   ```bash
   # List available Mullvad exit nodes
   tailscale exit-node list

   # Route all egress through one (keep LAN/tailnet reachable)
   sudo tailscale set --exit-node=<node-name> --exit-node-allow-lan-access

   # Confirm
   tailscale status
   ```
3. To stop using it:

   ```bash
   sudo tailscale set --exit-node=
   ```

Because this is pure Tailscale configuration, it survives image updates with
zero maintenance and leaves the base image vendor-neutral.

## Option B — standalone Mullvad client (advanced, your call)

If you specifically want Mullvad's own daemon/app on the host (e.g. to use a
Mullvad account directly, independent of Tailscale), layer it yourself with
`rpm-ostree`. This **re-introduces the vendor dependency on your machine** — a
deliberate choice you own, not a default we ship.

1. Add Mullvad's repo. The file below is the one this repo used to vendor; it
   pins `gpgcheck=1` so the package signature is verified against Mullvad's key
   at install time:

   ```ini
   # /etc/yum.repos.d/mullvad.repo
   [mullvad-stable]
   name=Mullvad VPN
   baseurl=https://repository.mullvad.net/rpm/stable/$basearch
   type=rpm
   enabled=1
   gpgcheck=1
   gpgkey=https://repository.mullvad.net/rpm/mullvad-keyring.asc
   ```
2. Layer and reboot:

   ```bash
   sudo rpm-ostree install mullvad-vpn
   sudo systemctl reboot
   ```
3. First-run login:

   ```bash
   mullvad account login <YOUR-ACCOUNT-NUMBER>
   mullvad connect
   ```
   Or use the Mullvad GUI app.

Maintenance note: layered packages are re-evaluated on every base update. If a
future base bump conflicts with `mullvad-vpn`, `rpm-ostree` will tell you; you
can `rpm-ostree uninstall mullvad-vpn` to get back to a clean base at any time.

## What this does *not* do

- **No VPN is active by default.** Both options are opt-in; the shipped image
  egresses normally until you configure one.
- **Option A trusts Tailscale + Mullvad's integration;** Option B trusts
  Mullvad's package repo (signature-verified) and adds a host daemon. Pick the
  trust surface you're comfortable with.
- **Neither replaces Tailscale for management.** Cockpit/SSH access still flows
  over the tailnet (see the README); the exit node only changes where your
  *outbound* traffic leaves from.
