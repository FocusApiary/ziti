.PHONY: help lint deploy deploy-metallb sync-images store-secrets configure-services configure-keycloak configure-oidc create-identities enroll-oidc-vms enroll-backup patch-coredns install-tunnel

help:
	@echo "Targets:"
	@echo "  make lint                — YAML + shellcheck"
	@echo "  make deploy              — Deploy controller + router"
	@echo "  make deploy-metallb      — Install MetalLB + IP pool"
	@echo "  make sync-images         — Mirror upstream images to Harbor"
	@echo "  make store-secrets       — Extract k8s secrets to AKV"
	@echo "  make configure-services  — Create Ziti services + policies"
	@echo "  make configure-keycloak  — Configure Keycloak OIDC client and roles for Ziti"
	@echo "  make configure-oidc      — Create Ziti ext-jwt-signer, auth-policy, OIDC + kiosk identities"
	@echo "  make create-identities   — Create employee identities (NAMES='a b')"
	@echo "  make enroll-oidc-vms     — Enroll OIDC identities on Curiosity Computer VMs via SSH"
	@echo "  make enroll-backup       — Enroll backup tunnel identities + store in AKV"
	@echo "  make patch-coredns       — Add service hostnames to CoreDNS"
	@echo "  make install-tunnel      — Install ziti-tunnel systemd service (sudo)"

lint:
	shellcheck scripts/*.sh
	@if command -v yamllint >/dev/null 2>&1; then yamllint -c .yamllint.yml .; else echo "yamllint not installed (skip)"; fi

deploy:
	scripts/deploy.sh

deploy-metallb:
	scripts/deploy_metallb.sh

sync-images:
	scripts/sync_images.sh

store-secrets:
	scripts/store_secrets.sh

configure-services:
	scripts/configure_services.sh

configure-keycloak:
	scripts/configure_keycloak_oidc.sh

configure-oidc:
	scripts/configure_oidc.sh

create-identities:
	scripts/create_identities.sh $(NAMES)

enroll-oidc-vms:
	scripts/enroll_oidc_identities.sh

enroll-backup:
	scripts/enroll_backup_identities.sh

patch-coredns:
	scripts/patch_coredns.sh

install-tunnel:
	sudo scripts/install_tunnel_service.sh
