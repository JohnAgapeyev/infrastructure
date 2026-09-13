.PHONY: status logs restart apply-cluster apply-media apply-home apply-observability apply-all

# NOTE: apps/* kustomizations reference repo-root secrets/ via
# secretGenerator, which requires LoadRestrictionsNone. `kubectl apply -k`
# has no load-restrictor flag, so we render with `kubectl kustomize` first.
KUSTOMIZE = kubectl kustomize --load-restrictor=LoadRestrictionsNone

status:
	./scripts/status.sh

logs:
	./scripts/logs.sh

restart:
	./scripts/restart.sh

apply-cluster:
	kubectl apply -k cluster/

apply-media:
	$(KUSTOMIZE) apps/media | kubectl apply -f -

apply-home:
	$(KUSTOMIZE) apps/home | kubectl apply -f -

# Observability is a Helm umbrella chart + kustomize exporters/dashboards/rules
apply-observability:
	helm dependency update apps/observability/kube-prometheus-stack
	helm upgrade --install observability apps/observability/kube-prometheus-stack \
		-n observability -f apps/observability/kube-prometheus-stack/values.yaml
	kubectl apply -k apps/observability/exporters
	kubectl apply -k apps/observability/dashboards
	kubectl apply -f apps/observability/rules/prometheusrule.yaml

apply-all: apply-cluster apply-media apply-home apply-observability
