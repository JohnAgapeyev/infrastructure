.PHONY: status logs restart apply-cluster apply-media apply-home apply-observability apply-all

status:
	./scripts/status.sh

logs:
	./scripts/logs.sh

restart:
	./scripts/restart.sh

apply-cluster:
	kubectl apply -k cluster/

apply-media:
	kubectl apply -k apps/media

apply-home:
	kubectl apply -k apps/home

# Observability is a Helm umbrella chart + kustomize exporters/dashboards/rules
apply-observability:
	helm dependency update apps/observability/kube-prometheus-stack
	helm upgrade --install observability apps/observability/kube-prometheus-stack \
		-n observability -f apps/observability/kube-prometheus-stack/values.yaml
	kubectl apply -k apps/observability/exporters
	kubectl apply -k apps/observability/dashboards
	kubectl apply -f apps/observability/rules/prometheusrule.yaml

apply-all: apply-cluster apply-media apply-home apply-observability
