.PHONY: check config lint wiki

check:
	python3 -m unittest discover -s tests -v

# Syntax validation with example values only; never deploy with these passwords.
config:
	for stack in stacks/*/ manager/; do \
		docker compose --project-directory $$stack -f $$stack/compose.yaml --env-file .env.example config --quiet || exit 1; \
	done
	for app in apps/*/; do \
		docker compose --project-directory $$app -f $$app/compose.yaml --env-file .env.example config --quiet || exit 1; \
		jq -e '.port and .upstream' $$app/app.json >/dev/null || exit 1; \
	done

lint:
	docker run --rm -v "$$PWD:/src:ro" -w /src koalaman/shellcheck:v0.10.0 -x -S warning \
		install.sh scripts/hbox scripts/hbox-mdns scripts/lib/*.sh scripts/generate-certs.sh $(wildcard migrations/*.sh)

# Publish wiki/ to the GitHub wiki. Links there have no .md suffix.
WIKI_REPO ?= https://github.com/ishrakr/hbox.wiki.git
wiki:
	set -e; dir=$$(mktemp -d); trap 'rm -rf "$$dir"' EXIT; \
	git clone -q $(WIKI_REPO) "$$dir"; \
	find "$$dir" -maxdepth 1 -name '*.md' -delete; \
	for f in wiki/*.md; do \
		sed -E 's#\]\(([A-Za-z0-9_-]+)\.md(\#[^)]*)?\)#](\1\2)#g' "$$f" > "$$dir/$$(basename "$$f")"; \
	done; \
	git -C "$$dir" add -A; \
	if git -C "$$dir" diff --cached --quiet; then echo "Wiki is up to date."; \
	else git -C "$$dir" commit -qm "Update from wiki/ at $$(git rev-parse --short HEAD)" && git -C "$$dir" push -q && echo "Wiki published."; fi
