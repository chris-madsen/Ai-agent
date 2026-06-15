# SSH MCP Server

## Install

```bash
git clone https://github.com/chris-madsen/Ai-agent
cd Ai-agent/ssh-mcp-server
make install CF_TOKEN="..." CF_DOMAIN="mcp.your-domain.com"
```

After install, add `https://mcp.your-domain.com/sse` as a Custom Remote Connector in Perplexity.

## Tools
- `ssh_execute` — run a shell command on a remote server
- `sftp_upload` — upload a file to a remote server
- `sftp_download` — download a file from a remote server

## Uninstall

```bash
make uninstall
```
