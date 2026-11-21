.PHONY: test unit integration e2e fault architecture \
	bench-eager bench-chaos bench-regression bench-acceptance verify

# NVIM is the binary every lane runs under; point it at a nightly build to
# check the plugin against Neovim before an update lands on PATH.
NVIM ?= nvim

# FILTER is a Lua pattern matched against test NAMES; SUITE selects one intent
# directory under test/. They compose: `make test SUITE=fault FILTER='^hl_'`.
test:
	$(NVIM) --headless --clean -l test/run.lua "$(FILTER)" "$(SUITE)"

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

# --- acceptance lanes --------------------------------------------------------
#
# Each lane writes JSON OUTSIDE the checkout and redirects Neovim's log there
# too, so running one never dirties the tree. Override OUT to place an artifact
# somewhere else; it must still resolve outside the repository.

OUT ?= /tmp/canvasdiff
NVIM_BENCH = $(NVIM) --headless --clean -n -i NONE

# The small-canvas baseline: what an ordinary review costs today.
bench-eager:
	NVIM_LOG_FILE=$(OUT)-eager.log $(NVIM_BENCH) \
		-l benchmark/run.lua $(OUT)-eager.json 5

# Surface-level deliberate breakage against a real Git fixture.
ACTIONS ?= 200
bench-chaos:
	NVIM_LOG_FILE=$(OUT)-chaos.log $(NVIM_BENCH) \
		-l benchmark/chaos/run.lua $(OUT)-chaos.json $(ACTIONS)

# Keep ordinary reviews fast against the frozen baseline.
bench-regression: bench-eager
	$(NVIM_BENCH) -l benchmark/regression.lua \
		docs/verification/eager-baseline.json $(OUT)-eager.json 10

# Interactive live acceptance in a real Git fixture.
bench-acceptance:
	NVIM_LOG_FILE=$(OUT)-acceptance.log $(NVIM_BENCH) \
		-l benchmark/acceptance/run.lua $(OUT)-acceptance.json

# Full verification suite.
verify:
	$(MAKE) test
	$(MAKE) bench-regression
	$(MAKE) bench-chaos
	$(MAKE) bench-acceptance
