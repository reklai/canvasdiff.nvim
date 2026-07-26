.PHONY: test
test:
	nvim --headless --clean -l test/run.lua $(FILTER)
