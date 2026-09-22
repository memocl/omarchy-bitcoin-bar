# Security

Please report suspected vulnerabilities privately through an X direct message to [@nmorton](https://x.com/nmorton). If direct messages are unavailable, contact the maintainer on X to request a private reporting channel without including vulnerability details.

Do not disclose suspected vulnerabilities in a public issue.

The plugin requires no API keys or accounts. Secrets, credentials, private endpoints, and personal data must not be committed to the repository.

The plugin writes one small state file, `${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-bitcoin-bar/api-host`. It holds the hostname of the mempool.space-compatible endpoint that last answered, so a blocked primary host is not retried on every refresh. Only hostnames compiled into `scripts/fetch-json.sh` are accepted, and nothing else is stored.
