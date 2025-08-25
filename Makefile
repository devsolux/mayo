VERSION ?= 1.0.0

info:
	# Find Developer ID signing identity
	security find-identity -v -p codesigning

sign:
	chmod +x ./sign-dmg.sh
	./sign-dmg.sh mayo-v1.0.0-macOS-arm64.dmg "Developer ID Application: Baris Aydin (589D596BW5)" mayo-v1.0.0-signed.dmg

verify:
	chmod +x ./verify-dmg.sh
	./verify-dmg.sh mayo-v1.0.0-signed.dmg