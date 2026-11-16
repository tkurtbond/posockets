# posockets -- TCP and Unix-domain sockets for poc, the Peaseblossom
# Oberon Compiler.  See AGENTS.md; adapted from polibfyaml's GNUmakefile.
#
# The library posockets is built in $(LIBDIR), with each module's C part
# (src/<Module>.c beside src/<Module>.Mod) compiled and archived with it.
# It links nothing beyond libc, so neither the library nor a program using
# it needs flags. The tests and examples take the library from there, so
# they test this checkout and what make install would install.
#
# poc writes each module's .sym, .ll and .o, and the programs, into $(BUILD).
# Every program writes the files of the modules it compiles into the same
# $(BUILD), so make must not build two at once.
#
# make install installs the library in $(POCLIBDIR), ~/.local/lib/poc by
# default, with and without debug information, under -OC, the only size
# model the library supports. poc puts each in <triple>/<variant>/ there.

POC      ?= poc
PREFIX ?= $(HOME)/.local
POCLIBDIR ?= $(PREFIX)/lib/poc
# The size model: decided in PLAN.md, "Integer model"; never mix models.
POCFLAGS := -OC
MODELS := OC
VARIANTS := $(MODELS) $(addsuffix -g,$(MODELS))
# --track-fds=yes makes valgrind list the descriptors open at exit; the
# valgrind target requires that the test opened none of them.
VALGRIND ?= valgrind --leak-check=full --show-leak-kinds=all --track-fds=yes --error-exitcode=99 --suppressions=poc-gc.supp

# An installed library on POC_LIBRARY_PATH would be taken in place of this
# checkout's source, or would stop the build if another poc wrote it.
unexport POC_LIBRARY_PATH

BUILD := build
LIBDIR := $(BUILD)/lib

LIBRARY := posockets
# The library's modules, in import order (PLAN.md, "Modules"). SocketTasks
# joins in Phase 4.
LIBMODS := Sockets

# $(call variant-flags,<variant>) gives poc's flags for a variant: OC-g gives
# -OC -g.
variant-flags = -$(firstword $(subst -, ,$(1))) $(if $(filter %-g,$(1)),-g)

# A library records the poc that built it, and another poc refuses it, so
# each library depends on poc itself.
POCBIN := $(shell command -v $(POC))

# The modules and their C parts, whichever have one.
LIBSRC := $(LIBMODS:%=src/%.Mod) $(wildcard $(LIBMODS:%=src/%.c))
# Test programs (test/<name>.Mod, each a main module).
TESTS := TestAddress TestBlocking TestErrors
# Programs the tests start (test/<name>.Mod), not tests themselves.
HELPERS := BlockingPeer TooManyFiles
# Programs that must halt (test/<name>.Mod), as name:Assert-code. poc's
# ASSERT(x, n) prints "assertion failed (n)" on standard error and exits
# with status 10, so `make test` requires both.
HALTTESTS := HaltClosed:80 HaltPort:84 HaltAddrs:84 HaltRange:81 HaltListening:85 \
  HaltAccept:85 HaltBacklog:84 HaltListeners:84 HaltShutdown:84
ASSERTSTATUS := 10

# Example programs (examples/<name>.Mod), as name:required-exit-status.
# `make test` runs each from examples/ and requires that status and
# stdout identical to examples/<name>.expected. None until Phase 8.
EXAMPLES :=

TESTBINS := $(TESTS:%=$(BUILD)/%)
HELPERBINS := $(HELPERS:%=$(BUILD)/%)
HALTBINS := $(foreach h,$(HALTTESTS),$(BUILD)/$(firstword $(subst :, ,$(h))))
EXAMPLEBINS := $(foreach e,$(EXAMPLES),$(BUILD)/$(firstword $(subst :, ,$(e))))

.PHONY: all tests test valgrind clean install uninstall
.NOTPARALLEL:

all: tests

tests: $(TESTBINS) $(HELPERBINS) $(HALTBINS) $(EXAMPLEBINS)

$(BUILD):
	mkdir -p $@

$(LIBDIR)/$(LIBRARY)-%.stamp: $(LIBSRC) $(POCBIN) | $(BUILD)
	mkdir -p $(LIBDIR)
	cd src && $(POC) $(call variant-flags,$*) -output-dir $(abspath $(LIBDIR)) \
	  -library $(LIBRARY) $(LIBMODS:%=%.Mod)
	touch $@

$(BUILD)/Test%: test/Test%.Mod test/Check.Mod test/TestHelp.Mod test/TestHelp.c $(LIBDIR)/$(LIBRARY)-OC.stamp | $(BUILD)
	$(POC) $(POCFLAGS) -library-path $(LIBDIR) -import-path test -output-dir $(BUILD) -o $@ $<

$(HELPERBINS): $(BUILD)/%: test/%.Mod test/TestHelp.Mod test/TestHelp.c $(LIBDIR)/$(LIBRARY)-OC.stamp | $(BUILD)
	$(POC) $(POCFLAGS) -library-path $(LIBDIR) -import-path test -output-dir $(BUILD) -o $@ $<

$(BUILD)/Halt%: test/Halt%.Mod $(LIBDIR)/$(LIBRARY)-OC.stamp | $(BUILD)
	$(POC) $(POCFLAGS) -library-path $(LIBDIR) -output-dir $(BUILD) -o $@ $<

$(BUILD)/Example%: examples/Example%.Mod $(LIBDIR)/$(LIBRARY)-OC.stamp | $(BUILD)
	$(POC) $(POCFLAGS) -library-path $(LIBDIR) -output-dir $(BUILD) -o $@ $<

# Run every test from test/; report all, fail at the end if any failed.
# Each halt test must exit with poc's ASSERT status and name its Assert
# code on standard error. Standard input is /dev/null.
test: tests
	@status=0; for t in $(TESTS); do \
	  echo "== $$t"; (cd test && ../$(BUILD)/$$t < /dev/null) || status=1; \
	done; \
	for h in $(HALTTESTS); do \
	  t=$${h%%:*}; code=$${h##*:}; echo "== $$t (must fail ASSERT code $$code)"; \
	  (cd test && ../$(BUILD)/$$t < /dev/null) 2> $(BUILD)/$$t.err; got=$$?; \
	  if [ $$got -eq $(ASSERTSTATUS) ] && grep -q "assertion failed ($$code)" $(BUILD)/$$t.err; then \
	    echo "ok   - $$t: $$(cat $(BUILD)/$$t.err)"; \
	  else echo "FAIL - $$t exited with $$got: $$(cat $(BUILD)/$$t.err)"; status=1; fi; \
	done; \
	for x in $(EXAMPLES); do \
	  e=$${x%%:*}; want=$${x##*:}; \
	  echo "== $$e (must exit $$want with examples/$$e.expected)"; \
	  (cd examples && ../$(BUILD)/$$e < /dev/null) > $(BUILD)/$$e.out; got=$$?; \
	  if [ $$got -eq $$want ] && cmp -s $(BUILD)/$$e.out examples/$$e.expected; then echo "ok   - $$e"; \
	  else echo "FAIL - $$e: exit $$got, output:"; diff examples/$$e.expected $(BUILD)/$$e.out; status=1; fi; \
	done; exit $$status

# Each test under valgrind. Besides definite and indirect leaks, every
# still-reachable block must be the collector's own (test/vg-reachable.sh),
# and every descriptor open at exit must be one the test inherited
# (test/vg-fds.sh, from valgrind's --track-fds=yes report).
valgrind: tests
	@status=0; for t in $(TESTS); do \
	  echo "== valgrind $$t"; \
	  (cd test && $(VALGRIND) --log-file=../$(BUILD)/$$t.vg ../$(BUILD)/$$t < /dev/null) || status=1; \
	  grep -E 'ERROR SUMMARY|lost:|reachable:|FILE DESCRIPTORS' $(BUILD)/$$t.vg; \
	  test/vg-reachable.sh $(BUILD)/$$t.vg || { echo "FAIL - $$t: still-reachable memory the collector did not allocate"; status=1; }; \
	  test/vg-fds.sh $(BUILD)/$$t.vg || { echo "FAIL - $$t: descriptors left open at exit (see $(BUILD)/$$t.vg)"; status=1; }; \
	done; exit $$status

# install copies the library, in each variant, into $(POCLIBDIR) with poc
# -install-library, which copies only what a program needs: the archive
# (the C parts' objects are in it), the shared object, the manifest, and
# each module's .sym and .owner. A program then finds it with -library-path
# $(POCLIBDIR). A library records the poc that built it, and another poc
# refuses it: install again after upgrading poc.
define newline


endef

install: $(foreach v,$(VARIANTS),$(LIBDIR)/$(LIBRARY)-$(v).stamp)
	$(foreach v,$(VARIANTS),$(POC) $(call variant-flags,$(v)) \
	  -library-path $(LIBDIR) -install-library $(LIBRARY) -output-dir $(POCLIBDIR)$(newline))

# uninstall removes from $(POCLIBDIR)/<triple>/<variant> what install put
# there. It leaves other libraries' files alone, and removes a directory only
# when nothing is left in it. The triple is poc's target.
INSTALLED_FILES := $(LIBRARY).library lib$(LIBRARY).a lib$(LIBRARY).so lib$(LIBRARY).so.0.0 \
  $(foreach m,$(LIBMODS),$(m).sym $(m).owner)

uninstall:
	@triple=$$($(POC) -version | sed -n 's/^target \([^ ]*\).*/\1/p'); \
	if [ -z "$$triple" ]; then echo "uninstall: cannot get the target from $(POC) -version" >&2; exit 1; fi; \
	for v in $(VARIANTS); do \
	  dir=$(POCLIBDIR)/$$triple/$$v; \
	  if [ -d "$$dir" ]; then \
	    echo "cd $$dir && rm -f $(INSTALLED_FILES)"; \
	    (cd "$$dir" && rm -f $(INSTALLED_FILES)) || exit 1; \
	    rmdir "$$dir" 2>/dev/null || :; \
	  fi; \
	done; \
	rmdir $(POCLIBDIR)/$$triple 2>/dev/null || :; \
	rmdir $(POCLIBDIR) 2>/dev/null || :

clean:
	rm -rf $(BUILD)
