.PHONY: app-preview marketing-screenshots marketing-screenshots-verify

app-preview:
	./marketing/app-preview/run.sh ios-main

marketing-screenshots:
	./marketing/screenshots/capture-all.sh

marketing-screenshots-verify:
	./marketing/screenshots/capture-all.sh --verify-only
