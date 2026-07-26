.PHONY: test unit integration e2e fault architecture

# FILTER is a Lua pattern matched against test NAMES; SUITE selects one intent
# directory under test/. They compose: `make test SUITE=fault FILTER='^hl_'`.
test:
	nvim --headless --clean -l test/run.lua "$(FILTER)" "$(SUITE)"

unit:
	$(MAKE) test SUITE=unit
integration:
	$(MAKE) test SUITE=integration
e2e:
	$(MAKE) test SUITE=e2e
fault:
	$(MAKE) test SUITE=fault
architecture:
	$(MAKE) test SUITE=architecture
