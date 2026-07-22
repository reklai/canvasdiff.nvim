.PHONY: test
test:
	nvim --headless --clean -l tests/run.lua $(FILTER)
