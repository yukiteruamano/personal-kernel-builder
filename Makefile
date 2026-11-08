# Development tasks for personal-kernel-builder: lint, tests and the Slackware package.
TOOL := personal-kernel-builder
SHELLCHECK ?= shellcheck

# Entry points only: shellcheck -x follows them into lib/, where checking a library on
# its own would flag every variable another library reads
LINT_SCRIPTS := $(TOOL)/$(TOOL) $(TOOL)/$(TOOL).SlackBuild $(TOOL)/$(TOOL).bash-completion \
	$(TOOL)/doinst.sh $(TOOL)/tests/unit.sh $(TOOL)/tests/completion.sh
BASH_SCRIPTS := $(TOOL)/$(TOOL) $(wildcard $(TOOL)/lib/*.sh) $(TOOL)/$(TOOL).SlackBuild \
	$(TOOL)/$(TOOL).bash-completion $(wildcard $(TOOL)/tests/*.sh)

.DEFAULT_GOAL := help
.PHONY: help check lint test package

help: ## Show the available targets
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN { FS = ":.*## " } { printf "  %-8s %s\n", $$1, $$2 }'

check: lint test ## Run lint and test

lint: ## Check the syntax of every script and run shellcheck
	@for script in $(BASH_SCRIPTS); do bash -n "$$script" || exit 1; done
	sh -n $(TOOL)/doinst.sh
	@if command -v zsh >/dev/null; then zsh -n $(TOOL)/$(TOOL).zsh-completion; fi
	$(SHELLCHECK) -x -P SCRIPTDIR -S style $(LINT_SCRIPTS)

test: ## Run the unit and completion tests
	$(TOOL)/tests/unit.sh
	$(TOOL)/tests/completion.sh

package: ## Build the Slackware package into /tmp (run as root)
	cd $(TOOL) && ./$(TOOL).SlackBuild
