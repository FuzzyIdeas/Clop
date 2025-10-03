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

.PHONY: build upload release setversion appcast bin

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
	rsync -avzP Releases/appcast.xml hetzner:/static/lowtechguys/clop/
	cfcli -d lowtechguys.com purge
	$(MAKE) sentry

release:
	gh release create v$(VERSION) -F ReleaseNotes/$(VERSION).md "Releases/Clop-$(VERSION).dmg#Clop.dmg"

sentry:
	op run -- sentry-cli upload-dif --include-sources -o alin-panaitiu -p clop --wait -- $(DERIVED_DATA_DIR)/Build/Intermediates.noindex/ArchiveIntermediates/Clop/BuildProductsPath/Release/

appcast: Releases/Clop-$(FULL_VERSION).html
	rm Releases/Clop.dmg || true
ifneq (, $(BETA))
	rm Releases/Clop$(FULL_VERSION)*.delta >/dev/null 2>/dev/null || true
	generate_appcast --channel beta --maximum-versions 10 --maximum-deltas $(DELTAS) --link "https://lowtechguys.com/clop" --full-release-notes-url "https://github.com/FuzzyIdeas/Clop/releases" --release-notes-url-prefix https://files.lowtechguys.com/ReleaseNotes/ --download-url-prefix "https://files.lowtechguys.com/releases/" -o Releases/appcast.xml Releases
else
	rm Releases/Clop$(FULL_VERSION)*.delta >/dev/null 2>/dev/null || true
	rm Releases/Clop-*b*.dmg >/dev/null 2>/dev/null || true
	rm Releases/Clop*b*.delta >/dev/null 2>/dev/null || true
	generate_appcast --maximum-versions 10 --maximum-deltas $(DELTAS) --link "https://lowtechguys.com/clop" --full-release-notes-url "https://github.com/FuzzyIdeas/Clop/releases" --release-notes-url-prefix https://files.lowtechguys.com/ReleaseNotes/ --download-url-prefix "https://files.lowtechguys.com/releases/" -o Releases/appcast.xml Releases
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
	pandoc -f gfm -o $@ --standalone --metadata title="Clop $(FULL_VERSION) - Release Notes" --css https://files.lowtechguys.com/release.css $(shell ls -t ReleaseNotes/$(VERSION)*.md)
else
	pandoc -f gfm -o $@ --standalone --metadata title="Clop $(FULL_VERSION) - Release Notes" --css https://files.lowtechguys.com/release.css ReleaseNotes/$(VERSION).md
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
