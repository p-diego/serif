APP = .build/Serif.app
BIN = .build/release
RES = Sources/Serif/Resources
INSTALLED = $(HOME)/Applications/Serif.app
DEV_HOME = /tmp/serif-dev
VERSION = $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' $(RES)/Info.plist)
ZIP = .build/Serif-$(VERSION).zip
DMG = .build/Serif-$(VERSION).dmg
STAGE = .build/dmg
# Signing: the keychain's "Apple Development" certificate when present, else ad-hoc (same rule as Siigil).
SIGN_ID = $(or $(shell security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $$2; exit}'),-)
SIGN = codesign --force --timestamp=none --sign $(SIGN_ID)

.PHONY: build install run test uninstall dist dmg release icon-layers

build:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(APP)/Contents/Library/LaunchAgents
	cp $(BIN)/Serif $(BIN)/serifd $(BIN)/serif-hook $(APP)/Contents/MacOS/
	cp $(RES)/Info.plist $(APP)/Contents/Info.plist
	cp $(RES)/com.serif.engine.plist $(APP)/Contents/Library/LaunchAgents/
	cp -R $(RES)/*.lproj $(APP)/Contents/Resources/
	# SwiftTerm's resources (its Metal shaders); SwiftTerm looks for them in Contents/Resources too.
	[ ! -d $(BIN)/SwiftTerm_SwiftTerm.bundle ] || cp -R $(BIN)/SwiftTerm_SwiftTerm.bundle $(APP)/Contents/Resources/
	# The icon (Icon Composer, made by `make icon-layers`): actool writes Assets.car (glass, macOS 26) and the .icns.
	# Absolute paths: actool hands the work to a service that resolves relative ones from elsewhere (as in Siigil).
	xcrun actool $(CURDIR)/$(RES)/icon/serif_icon.icon --compile $(CURDIR)/$(APP)/Contents/Resources --platform macosx \
		--minimum-deployment-target 26.0 --app-icon serif_icon --output-partial-info-plist /dev/null >/dev/null
	# Nested executables first, then the bundle (which signs Contents/MacOS/Serif); no --deep needed.
	$(SIGN) --identifier com.serif.engine $(APP)/Contents/MacOS/serifd
	$(SIGN) --identifier com.serif.hook $(APP)/Contents/MacOS/serif-hook
	$(SIGN) --identifier com.serif.app $(APP)

# Quits the app (only Serif: -x is an exact name), replaces the installed copy and opens it; the app registers itself
# and the engine (SMAppService). A running engine is restarted on the new binary; its bots resume their conversations.
install: build
	pkill -x Serif; while pgrep -x Serif >/dev/null; do sleep 0.1; done; true
	mkdir -p $(HOME)/Applications
	rm -rf $(INSTALLED) && cp -R $(APP) $(INSTALLED)
	# An engine the app started itself (agent not running) holds the data folder: stop it before launchd's restart.
	pkill -f '$(INSTALLED)/Contents/MacOS/serifd'; while pgrep -f '$(INSTALLED)/Contents/MacOS/serifd' >/dev/null; do sleep 0.1; done
	launchctl kickstart -k gui/$$(id -u)/com.serif.engine 2>/dev/null; true
	open $(INSTALLED)

# Development: an engine of its own on $(DEV_HOME) (a second one exits at once: the data folder is locked), then a new
# instance of the built app on the same folder (-n: the installed Serif may be running).
run: build
	SERIF_HOME=$(DEV_HOME) nohup $(CURDIR)/$(BIN)/serifd >/dev/null 2>&1 &
	open -n --env SERIF_HOME=$(DEV_HOME) $(APP)

test:
	swift test

# Removes the app and stops the engine; the data folder (~/Library/Application Support/Serif) stays.
uninstall:
	pkill -x Serif; while pgrep -x Serif >/dev/null; do sleep 0.1; done; true
	launchctl bootout gui/$$(id -u)/com.serif.engine 2>/dev/null; pkill -f '$(INSTALLED)/Contents/MacOS/serifd'; true
	rm -rf $(INSTALLED)

# Zip of the app (ditto keeps the bundle's signature and attributes).
dist: build
	ditto -c -k --keepParent $(APP) $(ZIP)
	@echo $(ZIP)

# Disk image, as Siigil's: the app and a link to Applications in a window with a dark background, arrow and first-launch
# note (dmg/background.swift draws it on every build; dmg/layout.applescript has Finder lay it out, which the first time
# asks whoever runs make for Automation). HFS+ read-write to set up the window, then converted compressed.
dmg: build
	rm -rf $(STAGE) $(DMG) .build/Serif-rw.dmg
	mkdir -p $(STAGE)/.background
	cp -R $(APP) $(STAGE)/
	ln -s /Applications $(STAGE)/Applications
	swift $(RES)/dmg/background.swift $(STAGE)/.background/background.png
	cp $(APP)/Contents/Resources/serif_icon.icns $(STAGE)/.VolumeIcon.icns
	hdiutil create -volname Serif -srcfolder $(STAGE) -fs HFS+ -format UDRW -ov -quiet .build/Serif-rw.dmg
	hdiutil attach -readwrite -noverify -noautoopen -quiet .build/Serif-rw.dmg
	command -v SetFile >/dev/null && SetFile -a C /Volumes/Serif || true
	osascript $(RES)/dmg/layout.applescript
	hdiutil detach -quiet /Volumes/Serif
	hdiutil convert -format UDZO -o $(DMG) -quiet .build/Serif-rw.dmg
	rm -f .build/Serif-rw.dmg
	@echo $(DMG)

# Publishes the zip and the DMG as GitHub Release v<version> (from Info.plist) on this repo's origin: tests green, a
# clean tree and a new version. The tag points at the local commit; the notes are its subject.
release: test dist dmg
	# Ad-hoc would reset the engine's login-item approval and the notification permission on every version.
	[ "$(SIGN_ID)" != "-" ] || { echo "No valid Apple Development certificate: refusing an ad-hoc release"; exit 1; }
	# New files too: the zip is built from the tree, the tag from the commit.
	[ -z "$$(git status --porcelain)" ] || { echo "Uncommitted changes or new files: commit first"; exit 1; }
	git tag v$(VERSION)
	git push origin v$(VERSION)
	gh release create v$(VERSION) $(ZIP) $(DMG) --verify-tag --notes "$$(git log -1 --format=%s)"

# Rewrites the icon's Icon Composer document from the mascot code (scripts/icon-layers): run it after changing the team
# there, then commit the .icon. Icon Composer can open the result for hand tweaks.
icon-layers:
	swiftc -O -o .build/icon-layers Sources/SerifCore/Mascot/*.swift scripts/icon-layers/main.swift
	.build/icon-layers $(RES)/icon/serif_icon.icon
