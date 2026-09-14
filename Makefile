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
	kubectl kustomize --load-restrictor=LoadRestrictionsNone apps/observability/kube-prometheus-stack | kubectl apply -f -
	helm dependency update apps/observability/kube-prometheus-stack
	helm upgrade --install observability apps/observability/kube-prometheus-stack \
		-n observability -f apps/observability/kube-prometheus-stack/values.yaml
	kubectl kustomize --load-restrictor=LoadRestrictionsNone apps/observability/exporters | kubectl apply -f -
	# server-side apply: large dashboard ConfigMaps exceed the 256 KiB
	# client-side last-applied annotation limit
	kubectl kustomize --load-restrictor=LoadRestrictionsNone apps/observability/dashboards | kubectl apply --server-side --force-conflicts -f -
	kubectl kustomize --load-restrictor=LoadRestrictionsNone apps/observability/rules | kubectl apply -f -

apply-all: apply-cluster apply-media apply-home apply-observability
