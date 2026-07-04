define n


endef

.EXPORT_ALL_VARIABLES:

BETA=
DELTAS=5

ifeq (, $(VERSION))
VERSION=$(shell rg -o --no-filename 'MARKETING_VERSION = ([^;]+).+' -r '$$1' *.xcodeproj/project.pbxproj | head -1 | sd 'b\d+' '')
endif

ifneq (, $(BETA))
FULL_VERSION:=$(VERSION)b$(BETA)
else
FULL_VERSION:=$(VERSION)
endif

RELEASE_NOTES_FILES := $(wildcard ReleaseNotes/*.md)
ENV=Release
DERIVED_DATA_DIR=$(shell ls -td $$HOME/Library/Developer/Xcode/DerivedData/Clop-* | head -1)
# Sparkle's generate_appcast ships as an SPM binary artifact, not on PATH. Resolve
# the newest one from the resolved SwiftPM artifacts, falling back to PATH.
GENERATE_APPCAST=$(or $(shell ls -t $$HOME/Library/Developer/Xcode/DerivedData/Clop-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast 2>/dev/null | head -1),generate_appcast)

SENTRY_ORG=alin-panaitiu
SENTRY_PROJECT=clop
DSYM_DIR=$(DERIVED_DATA_DIR)/Build/Intermediates.noindex/ArchiveIntermediates/Clop/BuildProductsPath/Release/
DSYM_UUID_FILE=Releases/dsym-uuids.txt
DSYM_OUT=/tmp/dsyms

.PHONY: build upload release setversion appcast bin changelog sentry record-dsyms download-dsym

print-%  : ; @echo $* = $($*)

build: SHELL=fish
build:
	make-app --build --devid --dmg -s Clop -t Clop -c Release --version $(FULL_VERSION)
	xcp /tmp/apps/Clop-$(FULL_VERSION).dmg Releases/

dmg: SHELL=fish
dmg:
	make-app --dmg -s Clop -t Clop -c Release --version $(FULL_VERSION) /tmp/apps/Clop.app
	xcp /tmp/apps/Clop-$(FULL_VERSION).dmg Releases/

upload:
	rsync -avzP Releases/*.{delta,dmg} hetzner:/static/lowtechguys/releases/ || true
	rsync -avz Releases/*.html hetzner:/static/lowtechguys/ReleaseNotes/
	rsync -avzP Releases/appcast.xml Releases/changelog.html hetzner:/static/lowtechguys/clop/
	cfcli -d lowtechguys.com purge
ifeq (, $(BETA))
	$(MAKE) sentry
endif

release:
	gh release create v$(VERSION) -F ReleaseNotes/$(VERSION).md "Releases/Clop-$(VERSION).dmg#Clop.dmg"
	git fetch --tags

sentry:
	env -u SENTRY_AUTH_TOKEN sentry-cli upload-dif --include-sources -o $(SENTRY_ORG) -p $(SENTRY_PROJECT) --wait -- $(DSYM_DIR)
	$(MAKE) record-dsyms

# Record the debug-IDs (UUIDs) of the dSYMs built for this version, keyed by version,
# into $(DSYM_UUID_FILE). Sentry stores dSYMs by debug-ID, not by version, so this map
# is what lets `make download-dsym VERSION=x.y.z` fetch the right ones later.
record-dsyms:
	@mkdir -p Releases
	@uuids=$$(find "$(DSYM_DIR)" -name '*.dSYM' -exec dwarfdump --uuid {} + 2>/dev/null | awk '{print tolower($$2)}' | sort -u | tr '\n' ' ' | sed 's/  *$$//'); \
	if [ -z "$$uuids" ]; then echo "record-dsyms: no dSYMs found under $(DSYM_DIR)"; exit 0; fi; \
	touch $(DSYM_UUID_FILE); \
	grep -v "^$(FULL_VERSION) =" $(DSYM_UUID_FILE) > $(DSYM_UUID_FILE).tmp 2>/dev/null || true; \
	echo "$(FULL_VERSION) = $$uuids" >> $(DSYM_UUID_FILE).tmp; \
	sort -Vr $(DSYM_UUID_FILE).tmp -o $(DSYM_UUID_FILE); rm -f $(DSYM_UUID_FILE).tmp; \
	echo "record-dsyms: $(FULL_VERSION) -> $$uuids"

# Download the dSYMs for a released version from Sentry (to symbolicate a crash later):
#   make download-dsym VERSION=x.y.z
# Resolves each recorded debug-ID to its file id and saves the dSYMs under $(DSYM_OUT).
download-dsym:
	@test -n "$(VERSION)" || { echo "Usage: make download-dsym VERSION=x.y.z"; exit 1; }
	@test -f $(DSYM_UUID_FILE) || { echo "No $(DSYM_UUID_FILE) yet; run 'make sentry' on a release build to record UUIDs"; exit 1; }
	@uuids=$$(awk -F' *= *' '$$1=="$(VERSION)"{print $$2}' $(DSYM_UUID_FILE)); \
	if [ -z "$$uuids" ]; then echo "No dSYM UUIDs recorded for $(VERSION). Recorded versions:"; cut -d= -f1 $(DSYM_UUID_FILE) | sed 's/  *$$//; s/^/  /'; exit 1; fi; \
	token=$$(sed -n 's/^ *token *= *//p' ~/.sentryclirc 2>/dev/null | head -1); \
	[ -n "$$token" ] || token=$$SENTRY_AUTH_TOKEN; \
	if [ -z "$$token" ]; then echo "No Sentry auth token found (~/.sentryclirc or \$$SENTRY_AUTH_TOKEN)"; exit 1; fi; \
	out=$(DSYM_OUT)/$(SENTRY_PROJECT)-$(VERSION); mkdir -p "$$out"; \
	api=https://sentry.io/api/0/projects/$(SENTRY_ORG)/$(SENTRY_PROJECT)/files/dsyms; \
	for u in $$uuids; do \
	  curl -fsSL -H "Authorization: Bearer $$token" "$$api/?debug_id=$$u" \
	    | python3 -c 'import json,sys; [print(o["id"], o["objectName"], o["cpuName"], (o.get("data") or {}).get("type","dbg")) for o in json.load(sys.stdin)]' \
	    | while read id obj cpu typ; do \
	        ext=debug; [ "$$typ" = src ] && ext=zip; \
	        echo "  $$obj ($$cpu, $$typ) [$$u] -> id $$id"; \
	        curl -fsSL -H "Authorization: Bearer $$token" "$$api/?id=$$id" -o "$$out/$$obj-$$cpu-$$typ-$$id.$$ext"; \
	      done; \
	done; \
	echo "Downloaded dSYMs for $(VERSION) to $$out"

CHANGELOG.md: $(RELEASE_NOTES_FILES)
	tail -n +1 $$(ls ReleaseNotes/*.md | egrep '/[0-9]+(\.[0-9]+)*\.md$$' $(if $(BETA),| egrep -v '/$(VERSION)\.md$$') | sort -Vr) | sd '==> ReleaseNotes/(.+)\.md <==' '# $$1\n\n**[Download Clop $$1 →](https://files.lowtechguys.com/releases/Clop-$$1.dmg)**' > CHANGELOG.md

Releases/changelog.html: CHANGELOG.md
	pandoc -f gfm --section-divs -o $@ --standalone --metadata title="Clop Changelog" --css https://files.lowtechguys.com/release.css --include-in-header=ReleaseNotes/changelog-head.html CHANGELOG.md

changelog: Releases/changelog.html

appcast: Releases/Clop-$(FULL_VERSION).html changelog
	rm Releases/Clop.dmg || true
ifneq (, $(BETA))
	rm Releases/Clop$(FULL_VERSION)*.delta >/dev/null 2>/dev/null || true
	$(GENERATE_APPCAST) --channel beta --maximum-versions 10 --maximum-deltas $(DELTAS) --link "https://lowtechguys.com/clop" --full-release-notes-url "https://files.lowtechguys.com/clop/changelog.html" --release-notes-url-prefix https://files.lowtechguys.com/ReleaseNotes/ --download-url-prefix "https://files.lowtechguys.com/releases/" -o Releases/appcast.xml Releases
else
	rm Releases/Clop$(FULL_VERSION)*.delta >/dev/null 2>/dev/null || true
	rm Releases/Clop-*b*.dmg >/dev/null 2>/dev/null || true
	rm Releases/Clop*b*.delta >/dev/null 2>/dev/null || true
	$(GENERATE_APPCAST) --maximum-versions 10 --maximum-deltas $(DELTAS) --link "https://lowtechguys.com/clop" --full-release-notes-url "https://files.lowtechguys.com/clop/changelog.html" --release-notes-url-prefix https://files.lowtechguys.com/ReleaseNotes/ --download-url-prefix "https://files.lowtechguys.com/releases/" -o Releases/appcast.xml Releases
	cp Releases/Clop-$(FULL_VERSION).dmg Releases/Clop.dmg
endif


setversion: OLD_VERSION=$(shell rg -o --no-filename 'MARKETING_VERSION = ([^;]+).+' -r '$$1' *.xcodeproj/project.pbxproj | head -1)
setversion: SHELL=fish
setversion:
ifneq (, $(FULL_VERSION))
	sdfk '((?:CURRENT_PROJECT|MARKETING)_VERSION) = $(OLD_VERSION);' '$$1 = $(FULL_VERSION);'
endif

Releases/Clop-%.html: ReleaseNotes/$(VERSION)*.md
	@echo Compiling $^ to $@
ifneq (, $(BETA))
	pandoc -f gfm --section-divs -o $@ --standalone --metadata title="Clop $(FULL_VERSION) - Release Notes" --css https://files.lowtechguys.com/release.css $(shell ls -t ReleaseNotes/$(VERSION)*.md)
else
	pandoc -f gfm --section-divs -o $@ --standalone --metadata title="Clop $(FULL_VERSION) - Release Notes" --css https://files.lowtechguys.com/release.css ReleaseNotes/$(VERSION).md
endif

NOTARIZE=1
Clop/bin.tar.lrz: PATH=$(shell echo $$PWD:$$PATH)
Clop/bin.tar.lrz: $(wildcard Clop/bin/*) $(wildcard Clop/bin/*/*)
	mkdir -p /tmp/tonotarize; rm /tmp/tonotarize.zip /tmp/tonotarize/* || true
	fd -uu -t file . Clop/bin -x zsh -c 'codesign -v -R="anchor apple generic" "{}" || { codesign -fs "$$CODESIGN_CERT" --options runtime --entitlements Clop/bin.entitlements --timestamp "{}" && cp "{}" /tmp/tonotarize/$$(jot -r 1)_{/} ; }'
ifeq (1, $(NOTARIZE))
	test $$(ls /tmp/tonotarize | wc -l) -gt 0 && zip -r /tmp/tonotarize.zip /tmp/tonotarize && \
		xcrun notarytool submit --progress --wait --keychain-profile Alin /tmp/tonotarize.zip
endif
	rm Clop/bin.tar.lrz; cd Clop/bin/; tar --lrzip -cf ../bin.tar.lrz *
	sha256sum Clop/bin.tar.lrz | cut -d' ' -f1 > Clop/bin.tar.lrz.sha256
bin: Clop/bin.tar.lrz

.PHONY: hooks
hooks:
	@ln -sf "$(CURDIR)/.pre-commit.sh" .git/hooks/pre-commit && echo "pre-commit hook installed -> .pre-commit.sh"
