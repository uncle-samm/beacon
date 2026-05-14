.PHONY: build test browser-canonical browser-canonical-desktop browser-canonical-mobile browser-all browser-all-desktop browser-all-mobile browser-all-shard browser-all-docker-shards push tag publish release

build:
	gleam build

test:
	gleam test

browser-canonical:
	sh scripts/run_canonical_cdp.sh

browser-canonical-desktop:
	BEACON_CDP_VIEWPORTS=desktop sh scripts/run_canonical_cdp.sh

browser-canonical-mobile:
	BEACON_CDP_VIEWPORTS=mobile sh scripts/run_canonical_cdp.sh

browser-all:
	sh scripts/run_all_cdp.sh

browser-all-desktop:
	BEACON_CDP_VIEWPORTS=desktop sh scripts/run_all_cdp.sh

browser-all-mobile:
	BEACON_CDP_VIEWPORTS=mobile sh scripts/run_all_cdp.sh

browser-all-shard:
	sh scripts/run_all_cdp.sh --shard "$${BEACON_CDP_SHARD:?set BEACON_CDP_SHARD=INDEX/TOTAL}"

browser-all-docker-shards:
	sh scripts/run_cdp_shards_docker.sh

push:
	sh scripts/push.sh

tag:
	sh scripts/tag.sh

publish:
	/usr/bin/expect scripts/publish.sh

release: push tag publish
