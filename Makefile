
push:
	@git add .
	@git commit -m "Updated at $$(date)" || true
	@git push

test-backup:
	@echo "Running backup with .env.test..."
	@mkdir -p tests/backups
	@docker compose -f tests/compose-test.yml up -d && sleep 5
	@set -a && . ./.env.test && bash backup.sh
	@echo "Backup completed."

test-clean:
	@echo "Cleaning test environment..."
	@docker compose -f tests/compose-test.yml down -v 2>/dev/null || true
	@sudo rm -rf tests/backups 2>/dev/null || rm -rf tests/backups 2>/dev/null || true
	@mkdir -p tests/backups
	@echo "Clean completed."
