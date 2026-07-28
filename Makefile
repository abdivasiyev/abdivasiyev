EMACS ?= emacs
PORT  ?= 4321

.PHONY: build serve clean

## build: assemble the deployable site into _site/
build:
	$(EMACS) --batch --load publish.el --funcall blog/publish

## serve: build, then serve _site/ on $(PORT)
# Serves _site/ specifically, so what you see locally is byte-for-byte what
# gets deployed.
serve: build
	@echo
	@echo "  CV     http://localhost:$(PORT)/"
	@echo "  Posts  http://localhost:$(PORT)/posts/"
	@echo
	@python3 -m http.server $(PORT) --directory _site

## clean: remove the built site and installed packages
clean:
	rm -rf _site .packages
