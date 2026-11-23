# Fast local loop. Xcode and these targets share the same DerivedData, so a build in one
# is reused by the other.
SCHEME = Domovy
XCB = xcodebuild -project Domovy.xcodeproj -scheme $(SCHEME) -configuration Debug -destination 'platform=macOS,arch=arm64' -quiet

.PHONY: app run test devhome reset-devhome cli clean

app: devhome            ## Build the app (Debug)
	$(XCB) build

run: app                ## Build and launch against .devhome
	@APP="$$($(XCB) -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR =/{print $$3; exit}')/Domovy.app"; \
	pkill -x Domovy 2>/dev/null || true; \
	DOMOVY_ROOT="$(CURDIR)/.devhome" "$$APP/Contents/MacOS/Domovy" -ApplePersistenceIgnoreState YES &

test:                   ## Core tests
	swift test

cli:                    ## Build the domo CLI
	swift build --product domo

devhome:
	@scripts/devhome.sh

reset-devhome:          ## Restore .devhome from fixtures (after trying deletes)
	@scripts/devhome.sh --reset

clean:
	$(XCB) clean
	swift package clean
