define n


endef

.EXPORT_ALL_VARIABLES:

BETA=

ifeq (, $(VERSION))
VERSION=$(shell rg -o --no-filename 'MARKETING_VERSION = ([^;]+).+' -r '$$1' *.xcodeproj/project.pbxproj | head -1)
endif

ifeq (beta, $(BETA))
FULL_VERSION:=$(VERSION)b$(BETA)
else
FULL_VERSION:=$(VERSION)
endif

RELEASE_NOTES_FILES := $(wildcard ReleaseNotes/*.md)
ENV=Release
DERIVED_DATA_DIR=$(shell ls -td $$HOME/Library/Developer/Xcode/DerivedData/Clop-* | head -1)

print-%  : ; @echo $* = $($*)

upload:
	rsync -avz Releases/*.delta hetzner:/static/lowtechguys/deltas/ || true
	rsync -avzP Releases/*.dmg hetzner:/static/lowtechguys/releases/
	rsync -avz Releases/*.html hetzner:/static/lowtechguys/ReleaseNotes/
	rsync -avzP Releases/appcast.xml hetzner:/static/lowtechguys/clop/
	cfcli -d lowtechguys.com purge

release:
	gh release create v$(VERSION) -F ReleaseNotes/$(VERSION).md "Releases/Clop-$(VERSION).dmg#Clop.dmg"

sentry:
	sentry-cli upload-dif --include-sources -o alin-panaitiu -p clop --wait -- $(DERIVED_DATA_DIR)/Build/Intermediates.noindex/ArchiveIntermediates/Clop/BuildProductsPath/Release/

appcast: Releases/Clop-$(FULL_VERSION).html
	rm Releases/Clop.dmg || true
ifneq (, $(BETA))
	rm Releases/Clop$(FULL_VERSION)*.delta >/dev/null 2>/dev/null || true
	generate_appcast --channel beta --maximum-versions 10 --link "https://lowtechguys.com/clop" --full-release-notes-url "https://github.com/FuzzyIdeas/Clop/releases" --release-notes-url-prefix https://files.lowtechguys.com/ReleaseNotes/ --download-url-prefix "https://files.lowtechguys.com/releases/" -o Releases/appcast.xml Releases
else
	rm Releases/Clop$(FULL_VERSION)*.delta >/dev/null 2>/dev/null || true
	rm Releases/Clop-*b*.dmg >/dev/null 2>/dev/null || true
	rm Releases/Clop*b*.delta >/dev/null 2>/dev/null || true
	generate_appcast --maximum-versions 10 --link "https://lowtechguys.com/clop" --full-release-notes-url "https://github.com/FuzzyIdeas/Clop/releases" --release-notes-url-prefix https://files.lowtechguys.com/ReleaseNotes/ --download-url-prefix "https://files.lowtechguys.com/releases/" -o Releases/appcast.xml Releases
	cp Releases/Clop-$(FULL_VERSION).dmg Releases/Clop.dmg
endif


setversion: OLD_VERSION=$(shell rg -o --no-filename 'MARKETING_VERSION = ([^;]+).+' -r '$1' | head -1)
setversion:
ifneq (, $(FULL_VERSION))
	rg -l 'VERSION = "?$(OLD_VERSION)"?' && sed -E -i .bkp 's/VERSION = "?$(OLD_VERSION)"?/VERSION = $(FULL_VERSION)/g' $$(rg -l 'VERSION = "?$(OLD_VERSION)"?')
endif

Releases/Clop-%.html: ReleaseNotes/$(VERSION)*.md
	@echo Compiling $^ to $@
ifneq (, $(BETA))
	pandoc -f gfm -o $@ --standalone --metadata title="Clop $(FULL_VERSION) - Release Notes" --css https://files.lowtechguys.com/release.css $(shell ls -t ReleaseNotes/$(VERSION)*.md)
else
	pandoc -f gfm -o $@ --standalone --metadata title="Clop $(FULL_VERSION) - Release Notes" --css https://files.lowtechguys.com/release.css ReleaseNotes/$(VERSION).md
endif
