-- Window of the "Serif" DMG mounted at /Volumes/Serif (make dmg): icon view at 128, background, positions.
-- The first time, macOS asks whoever runs make for permission to control Finder (Automation).
tell application "Finder"
	tell disk "Serif"
		open
		set current view of container window to icon view
		set toolbar visible of container window to false
		set statusbar visible of container window to false
		set the bounds of container window to {200, 120, 840, 548}
		set opts to the icon view options of container window
		set arrangement of opts to not arranged
		set icon size of opts to 128
		set text size of opts to 13
		set background picture of opts to file ".background:background.png"
		set position of item "Serif.app" of container window to {160, 180}
		set position of item "Applications" of container window to {480, 180}
		update without registering applications
		delay 1
		close
	end tell
end tell
