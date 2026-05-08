.PHONY: build test browser-canonical browser-canonical-desktop browser-canonical-mobile browser-all browser-all-desktop browser-all-mobile push tag publish release

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

push:
	sh scripts/push.sh

tag:
	sh scripts/tag.sh

publish:
	/usr/bin/expect scripts/publish.sh

release: push tag publish
