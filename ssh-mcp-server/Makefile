install:
	@[ -n "$(CF_TOKEN)" ] || (echo "CF_TOKEN required"; exit 1)
	@[ -n "$(CF_DOMAIN)" ] || (echo "CF_DOMAIN required"; exit 1)
	sudo -E CF_TOKEN=$(CF_TOKEN) CF_DOMAIN=$(CF_DOMAIN) MCP_PORT=$(or $(MCP_PORT),8080) bash install.sh

uninstall:
	sudo bash uninstall.sh

deploy:
	git pull origin master
	scp -i "openvpn-ee-ssh.pem" -r * ubuntu@ec2-3-222-67-107.compute-1.amazonaws.com:/home/ubuntu/ssh-mcp-server/