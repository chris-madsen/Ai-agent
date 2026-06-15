install:
	@[ -n "$(CF_TOKEN)" ] || (echo "CF_TOKEN required"; exit 1)
	@[ -n "$(CF_DOMAIN)" ] || (echo "CF_DOMAIN required"; exit 1)
	sudo -E CF_TOKEN=$(CF_TOKEN) CF_DOMAIN=$(CF_DOMAIN) bash install.sh

uninstall:
	sudo bash uninstall.sh
