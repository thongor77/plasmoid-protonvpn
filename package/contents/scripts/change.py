#!/usr/bin/env python3
"""Connect to a Proton VPN server, including free-plan hops the CLI refuses.

The official CLI rejects `protonvpn connect NAME` and `--random` on the free
plan, even when NAME is a free-tier exit. That gate is product policy in
`Controller.find_logical_server`, not an API limit. The desktop app talks to
the same session API without it. So does this script, still refusing anything
above the user's tier.

Usage:
  change.py --current <SERVER_NAME> [--free]   another in-tier server
  change.py --to <SERVER_NAME>                 that server, if in-tier
"""
from __future__ import annotations

import argparse
import asyncio
import sys

from proton.session.exceptions import ProtonAPIError, ProtonAPINotReachable
from proton.vpn.cli.core.controller import Controller, Params
from proton.vpn.session.exceptions import ServerNotFoundError

from servers import location_of, logicals_as_cache, shuffle_server


class _ClickRoot:
    """Minimal stand-in so Controller.program_name does not explode."""

    info_name = "protonvpn"

    def find_root(self):
        return self


def resolve_server(server_list, name):
    """Look up a logical server by name, or None if the list has no such row."""
    try:
        return server_list.get_by_name(name)
    except ServerNotFoundError:
        return None


async def hop(current: str, free_only: bool, to_name: str) -> int:
    """Connect to `to_name`, or to another in-tier server. Returns an exit code."""
    controller = await Controller.create(
        params=Params(allow_gui_concurrency=True),
        click_ctx=_ClickRoot(),
    )
    if not controller.is_logged_in:
        print("Not signed in.", file=sys.stderr)
        return 1

    server_list = await controller.get_updated_server_list()
    if to_name.strip() != "":
        name = to_name.strip()
    else:
        picked = shuffle_server(
            logicals_as_cache(server_list.logicals),
            current,
            free_only,
        )
        name = (picked or {}).get("name") or ""
        if name == "":
            msg = "No other free server available" if free_only else "No other server available"
            print(msg, file=sys.stderr)
            return 1

    server = resolve_server(server_list, name)
    if server is None:
        print(f"Invalid server ID '{name}'.", file=sys.stderr)
        return 1
    if int(server.tier) > int(controller.user_tier):
        print("Requires a Proton VPN Plus plan", file=sys.stderr)
        return 1

    connection_state = await controller.connect(server)
    if not connection_state:
        print("Connection failed. Try a different server.", file=sys.stderr)
        return 1

    current_connection = connection_state.context.connection
    print(f"Connected to {current_connection.server_name} in {location_of(server)}.")
    return 0


def main() -> int:
    """Parse argv and hop. Returns a process exit code."""
    parser = argparse.ArgumentParser(description="Change Proton VPN server")
    parser.add_argument("--current", default="", help="Server to leave when shuffling")
    parser.add_argument("--to", default="", dest="to_name", help="Connect to this server")
    parser.add_argument(
        "--free",
        action="store_true",
        help="Only pick tier-0 (free) exits when shuffling",
    )
    args = parser.parse_args()
    try:
        return asyncio.run(hop(args.current, args.free, args.to_name))
    except ProtonAPIError as exc:
        print(getattr(exc, "message", None) or str(exc), file=sys.stderr)
        return 1
    except (TimeoutError, ProtonAPINotReachable):
        print("Network connectivity issues detected.", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
