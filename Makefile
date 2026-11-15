.PHONY: setup format lint test dialyzer openapi ci clean contract-deps-up contract-deps-down contract-test

-include .env
export

setup:
	mix local.hex --force
	mix local.rebar --force
	mix deps.get

format:
	mix format

lint:
	mix credo --strict

test:
	MIX_ENV=test mix coveralls

dialyzer:
	mix dialyzer

openapi:
	mix openapi.spec.yaml --spec NotificationsWeb.ApiSpec openapi.yaml

# Prueba de contrato (Schemathesis contra el servicio real). Contenedores propios, puertos de host
# 55517 (RabbitMQ) y 55527 (Mongo); el servicio corre en 18087.
CONTRACT_MONGO_PORT ?= 55527
CONTRACT_RABBITMQ_PORT ?= 55517

contract-deps-up:
	@docker rm -f contract-notifications-mongo contract-notifications-rabbitmq >/dev/null 2>&1 || true
	docker run -d --name contract-notifications-mongo -p 127.0.0.1:$(CONTRACT_MONGO_PORT):27017 mongo:7 >/dev/null
	docker run -d --name contract-notifications-rabbitmq -p 127.0.0.1:$(CONTRACT_RABBITMQ_PORT):5672 rabbitmq:3.13-management-alpine >/dev/null
	@until docker exec contract-notifications-mongo mongosh --quiet --eval 'db.runCommand({ping: 1})' >/dev/null 2>&1; do sleep 2; done
	@until docker exec contract-notifications-rabbitmq rabbitmq-diagnostics -q ping >/dev/null 2>&1; do sleep 2; done
	@echo "Mongo en $(CONTRACT_MONGO_PORT) y RabbitMQ en $(CONTRACT_RABBITMQ_PORT) listos"

contract-deps-down:
	@docker rm -f contract-notifications-app contract-notifications-mongo contract-notifications-rabbitmq >/dev/null 2>&1 || true
	@echo "Contenedores de contrato apagados"

contract-test:
	APP_PORT=18087 	MONGO_URL=mongodb://localhost:$(CONTRACT_MONGO_PORT)/notifications_contract 	RABBITMQ_URL=amqp://guest:guest@localhost:$(CONTRACT_RABBITMQ_PORT) 	./scripts/contract-test.sh

ci: ## corre lo mismo que el pipeline de CI, en local
	@echo "--- format ---"
	mix format --check-formatted
	@echo "--- credo ---"
	mix credo --strict
	@echo "--- compile ---"
	mix compile --warnings-as-errors
	@echo "--- sobelow ---"
	mix sobelow --config
	@echo "--- test ---"
	MIX_ENV=test mix coveralls
	@echo "--- dialyzer ---"
	mix dialyzer
	@echo "Todo OK"

clean:
	rm -rf _build deps
	@echo "Build limpio. Corre \"make setup\" de nuevo."
