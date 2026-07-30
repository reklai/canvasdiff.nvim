.PHONY: test unit integration e2e fault architecture \
	bench-eager bench-paged bench-chaos bench-regression bench-acceptance \
	bench-live-scale verify

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

# --- acceptance lanes --------------------------------------------------------
#
# Each lane writes JSON OUTSIDE the checkout and redirects Neovim's log there
# too, so running one never dirties the tree. Override OUT to place an artifact
# somewhere else; it must still resolve outside the repository.

OUT ?= /tmp/canvasdiff
NVIM_BENCH = nvim --headless --clean -n -i NONE

# The frozen small-canvas baseline: what an ordinary review costs today.
bench-eager:
	NVIM_LOG_FILE=$(OUT)-eager.log $(NVIM_BENCH) \
		-l benchmark/run.lua $(OUT)-eager.json 5

# The million-row gate. REPS defaults to the journey's three repetitions.
REPS ?= 3
bench-paged:
	NVIM_LOG_FILE=$(OUT)-paged.log $(NVIM_BENCH) \
		-l benchmark/paged/run.lua $(OUT)-paged.json $(REPS)

# Phase 7 deliberate breakage. ACTIONS defaults to the journey's 10,000.
ACTIONS ?= 10000
bench-chaos:
	NVIM_LOG_FILE=$(OUT)-chaos.log $(NVIM_BENCH) \
		-l benchmark/chaos/run.lua $(OUT)-chaos.json $(ACTIONS)

# Speeding up a million rows must not slow the ordinary review down.
bench-regression: bench-eager
	$(NVIM_BENCH) -l benchmark/regression.lua \
		docs/verification/eager-baseline.json $(OUT)-eager.json 10

# Phase 8: the eight live interactions in a real Git fixture, with the
# observations recorded as evidence rather than asserted and discarded.
bench-acceptance:
	NVIM_LOG_FILE=$(OUT)-acceptance.log $(NVIM_BENCH) \
		-l benchmark/acceptance/run.lua $(OUT)-acceptance.json

# The expensive real-Git ladder: one isolated worker per requested size.
LIVE_REPS ?= 1
bench-live-scale:
	NVIM_LOG_FILE=$(OUT)-live-scale.log $(NVIM_BENCH) \
		-l benchmark/live_scale/run.lua $(OUT)-live-scale.json \
		$(LIVE_REPS) "$(SIZES)" "$(BASELINE)"

# Everything a publication audit has to show, in one command.
verify:
	$(MAKE) test
	$(MAKE) bench-regression
	$(MAKE) bench-paged
	$(MAKE) bench-chaos
	$(MAKE) bench-acceptance
