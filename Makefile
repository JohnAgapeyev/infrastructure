.PHONY: status logs restart apply-cluster install-cert-manager apply-media apply-home apply-observability apply-cloud apply-ai apply-all

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
	# cert-manager/ kustomization pulls ../../secrets/*.env via
	# secretGenerator -> needs LoadRestrictionsNone (see NOTE above)
	$(KUSTOMIZE) cluster/ | kubectl apply -f -

install-cert-manager:
	./scripts/install-cert-manager.sh

apply-media:
	$(KUSTOMIZE) apps/media | kubectl apply -f -

apply-home:
	$(KUSTOMIZE) apps/home | kubectl apply -f -

apply-cloud:
	$(KUSTOMIZE) apps/cloud | kubectl apply -f -

apply-ai:
	$(KUSTOMIZE) apps/ai | kubectl apply -f -

# Observability is a Helm umbrella chart + kustomize exporters/dashboards/rules
apply-observability:
	kubectl kustomize --load-restrictor=LoadRestrictionsNone apps/observability/kube-prometheus-stack | kubectl apply -f -
	helm dependency update apps/observability/kube-prometheus-stack
	helm upgrade --install observability apps/observability/kube-prometheus-stack \
		-n observability -f apps/observability/kube-prometheus-stack/values.yaml
	kubectl kustomize --load-restrictor=LoadRestrictionsNone apps/observability/exporters | kubectl apply -f -
	# notification sinks: ntfy + the Alertmanager->ntfy bridge (plan:
	# severity routing is in kube-prometheus-stack/values.yaml; first-deploy
	# runbook in apps/observability/notify/kustomization.yaml)
	kubectl kustomize --load-restrictor=LoadRestrictionsNone apps/observability/notify | kubectl apply -f -
	# server-side apply: large dashboard ConfigMaps exceed the 256 KiB
	# client-side last-applied annotation limit
	kubectl kustomize --load-restrictor=LoadRestrictionsNone apps/observability/dashboards | kubectl apply --server-side --force-conflicts -f -
	kubectl kustomize --load-restrictor=LoadRestrictionsNone apps/observability/rules | kubectl apply -f -

apply-all: apply-cluster apply-media apply-home apply-cloud apply-ai apply-observability
