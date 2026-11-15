.PHONY: check config lint

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
