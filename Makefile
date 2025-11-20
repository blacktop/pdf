.PHONY: bump
bump:
	@echo "👊 Bumping Version"
	git tag $(shell svu patch)
	git push --tags

.PHONY: build
build:
	@echo "🔨 Building Version $(shell svu current)"
	swift build --disable-sandbox

.PHONY: release
release:
	@echo "🚀 Releasing Version $(shell svu current)"
	swift build -c release

.PHONY: test
test:
	@echo "🧪 Testing Version $(shell svu current)"
	swift test --disable-sandbox
