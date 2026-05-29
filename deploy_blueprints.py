#!/usr/bin/env python3
"""
deploy_blueprints.py

Deploys all .yaml/.yml files from the `authentik_blueprints/` directory to an
Authentik instance using its managed blueprints API.

Credential resolution order (first match wins):
  1. Environment variables  AUTHENTIK_URL  +  AUTHENTIK_TOKEN
  2. Terraform outputs from stages/04-authentik  (runs `terraform output -json`)
     + AWS Secrets Manager (boto3) for the API token

Each file is deployed as a persistent BlueprintInstance (upsert by name extracted
from the YAML `metadata.name` field), then applied immediately.
"""

import json
import logging
import os
import subprocess
import sys
from pathlib import Path

import requests
import yaml

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Placeholder written by Terraform before the real token is set
_TOKEN_PLACEHOLDER = "REPLACE_WITH_AUTHENTIK_API_TOKEN"

# Blueprint file that defines the primary authentication flow.
# After a successful deploy the script updates the default brand to use it.
_AUTH_FLOW_BLUEPRINT = "default-authentication-flow.yaml"

BLUEPRINTS_DIR = Path(__file__).parent / "authentik_blueprints"
TF_STAGE_DIR = Path(__file__).parent / "stages" / "04-authentik"
API_BASE = "/api/v3"
TIMEOUT = 30  # seconds

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Credential resolution
# ---------------------------------------------------------------------------

def _load_from_env() -> tuple[str, str] | None:
    """Return (url, token) from env vars, or None if either is missing."""
    url = os.environ.get("AUTHENTIK_URL", "").rstrip("/")
    token = os.environ.get("AUTHENTIK_TOKEN", "")
    if url and token:
        log.info("Using credentials from environment variables.")
        return url, token
    return None


def _load_from_terraform() -> tuple[str, str]:
    """
    Read authentik_url and authentik_api_token_secret_arn from Terraform outputs
    (stages/04-authentik), then fetch the actual token from AWS Secrets Manager.

    Requires:
      - `terraform` CLI in PATH, already initialised in TF_STAGE_DIR
      - AWS credentials with secretsmanager:GetSecretValue permission (boto3)
    """
    try:
        import boto3
    except ImportError:
        log.error(
            "boto3 is not installed. Install it with: pip install boto3\n"
            "Alternatively, set AUTHENTIK_URL and AUTHENTIK_TOKEN environment variables."
        )
        sys.exit(1)

    log.info("Reading Terraform outputs from %s …", TF_STAGE_DIR)

    try:
        result = subprocess.run(
            ["terraform", "output", "-json"],
            cwd=TF_STAGE_DIR,
            capture_output=True,
            text=True,
            check=True,
        )
    except FileNotFoundError:
        log.error(
            "`terraform` binary not found in PATH. "
            "Install Terraform or set AUTHENTIK_URL and AUTHENTIK_TOKEN manually."
        )
        sys.exit(1)
    except subprocess.CalledProcessError as exc:
        log.error("terraform output failed:\n%s", exc.stderr.strip())
        sys.exit(1)

    try:
        tf_outputs = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        log.error("Could not parse terraform output JSON: %s", exc)
        sys.exit(1)

    missing = [k for k in ("authentik_url", "authentik_api_token_secret_arn") if k not in tf_outputs]
    if missing:
        log.error(
            "Required Terraform output(s) not found: %s\n"
            "Make sure you have run `terraform apply` in %s.",
            ", ".join(missing),
            TF_STAGE_DIR,
        )
        sys.exit(1)

    authentik_url = tf_outputs["authentik_url"]["value"].rstrip("/")
    secret_arn = tf_outputs["authentik_api_token_secret_arn"]["value"]

    log.info("Authentik URL from Terraform: %s", authentik_url)
    log.info("Fetching API token from Secrets Manager: %s", secret_arn)

    try:
        sm = boto3.client("secretsmanager")
        secret_resp = sm.get_secret_value(SecretId=secret_arn)
    except Exception as exc:
        log.error("Failed to retrieve secret from AWS Secrets Manager: %s", exc)
        sys.exit(1)

    try:
        secret_data = json.loads(secret_resp["SecretString"])
        token = secret_data["password"]
    except (json.JSONDecodeError, KeyError) as exc:
        log.error(
            "Could not parse secret value from %s. "
            "Expected JSON with a 'password' field. Error: %s",
            secret_arn,
            exc,
        )
        sys.exit(1)

    if token == _TOKEN_PLACEHOLDER:
        log.error(
            "The API token in Secrets Manager is still the Terraform placeholder.\n"
            "  Secret: %s\n\n"
            "  Steps to fix:\n"
            "    1. Log in to Authentik at %s\n"
            "    2. Go to Admin → Directory → Tokens → Create token (Intent: API)\n"
            "    3. Copy the generated token key\n"
            "    4. Update the secret:\n"
            "       aws secretsmanager put-secret-value \\\n"
            "         --secret-id '%s' \\\n"
            "         --secret-string '{\"username\":\"akadmin\",\"password\":\"<TOKEN>\"}'\n",
            secret_arn,
            authentik_url,
            secret_arn,
        )
        sys.exit(1)

    log.info("API token retrieved from Secrets Manager.")
    return authentik_url, token


def _resolve_credentials() -> tuple[str, str]:
    """
    Return (authentik_url, token) using the resolution order:
      1. Environment variables
      2. Terraform + AWS Secrets Manager
    """
    creds = _load_from_env()
    if creds:
        return creds

    log.info(
        "AUTHENTIK_URL or AUTHENTIK_TOKEN not set – "
        "attempting to resolve from Terraform outputs."
    )
    return _load_from_terraform()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

class _AuthentikYamlLoader(yaml.SafeLoader):
    """
    SafeLoader extended to tolerate Authentik-specific YAML tags such as
    !KeyOf, !Find, !Env, !Format, etc.

    Authentik tags can be applied to scalars (!KeyOf id), sequences
    (!Find [model, criteria]) or mappings, so the constructor must handle
    all three node types.  Unknown-tagged nodes are reduced to their plain
    Python value so that metadata.name can always be extracted.
    """


def _authentik_tag_constructor(
    loader: yaml.SafeLoader, tag_suffix: str, node: yaml.Node
) -> object:
    if isinstance(node, yaml.ScalarNode):
        return loader.construct_scalar(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node, deep=True)
    if isinstance(node, yaml.MappingNode):
        return loader.construct_mapping(node, deep=True)
    return None


# Register the constructor for every unknown tag prefix (empty string = catch-all).
_AuthentikYamlLoader.add_multi_constructor("", _authentik_tag_constructor)


def _session(token: str) -> requests.Session:
    s = requests.Session()
    s.headers.update({"Authorization": f"Bearer {token}", "Accept": "application/json"})
    return s


def _verify_token(session: requests.Session, api_root: str) -> None:
    """
    Check the token against /api/v3/core/tokens/ before deploying anything.
    Exits with a clear message on 401/403 instead of letting each blueprint fail.
    """
    try:
        # /core/users/me/ returns the User object for the token's owner.
        # Authentik returns {"username": ..., "is_superuser": ..., "name": ...}
        resp = session.get(f"{api_root}/core/users/me/", timeout=TIMEOUT)
    except requests.ConnectionError as exc:
        log.error("Cannot reach Authentik at %s: %s", api_root, exc)
        sys.exit(1)

    if resp.status_code == 401:
        log.error(
            "API token rejected (401 Unauthorized).\n"
            "  The token may be incorrect or not yet created in Authentik.\n"
            "  Check the value in AWS Secrets Manager and re-run."
        )
        sys.exit(1)
    if resp.status_code == 403:
        log.error(
            "API token accepted but lacks required permissions (403 Forbidden).\n"
            "  Make sure the token belongs to a superuser (akadmin) or a service\n"
            "  account with 'Blueprint instances' read/write permissions."
        )
        sys.exit(1)

    resp.raise_for_status()
    # Authentik wraps the response: {"user": {...}} in some versions, bare object in others.
    body = resp.json()
    me = body.get("user", body)
    username = me.get("username") or me.get("name", "unknown")
    is_super = me.get("is_superuser", False)
    log.info("Authenticated as '%s' (is_superuser=%s).", username, is_super)
    if not is_super:
        log.warning(
            "User '%s' is NOT a superuser – blueprint deployment may fail with 403.",
            username,
        )


def _extract_name(yaml_path: Path) -> str:
    """
    Return metadata.name from the YAML file using the Authentik-aware loader.
    Falls back to the file stem if the field is absent or the file is unparseable.
    """
    try:
        data = yaml.load(yaml_path.read_text(encoding="utf-8"), Loader=_AuthentikYamlLoader)
        name = data.get("metadata", {}).get("name", "")
        if name:
            return name
        log.warning("[%s] metadata.name is empty; using filename as name.", yaml_path.name)
    except yaml.YAMLError as exc:
        log.warning("Could not parse YAML in %s (%s); using filename as name.", yaml_path.name, exc)
    return yaml_path.stem


def _find_existing(session: requests.Session, api_root: str, name: str) -> dict | None:
    """Return the first BlueprintInstance with the given name, or None."""
    resp = session.get(f"{api_root}/managed/blueprints/", params={"name": name}, timeout=TIMEOUT)
    resp.raise_for_status()
    results = resp.json().get("results", [])
    return results[0] if results else None


def _format_api_error(resp: requests.Response) -> str:
    try:
        body = resp.json()
        if isinstance(body, dict):
            if "detail" in body:
                return body["detail"]
            return "; ".join(
                f"{k}: {', '.join(v) if isinstance(v, list) else v}"
                for k, v in body.items()
            )
        return str(body)
    except Exception:
        return resp.text[:500]


# ---------------------------------------------------------------------------
# Pre-deploy conflict cleanup
# ---------------------------------------------------------------------------

# Authentik runs the blueprint importer during content validation (server-side),
# which creates objects even when validation ultimately fails.  Subsequent runs
# hit name-uniqueness conflicts on those "ghost" objects.
# This map declares which Authentik API collection to query for each model.
_MODEL_TO_API: dict[str, str] = {
    "authentik_policies_expression.expressionpolicy": "policies/expression",
    "authentik_policies_event_matcher.eventmatcherpolicy": "policies/event_matcher",
    "authentik_policies_password.passwordpolicy": "policies/password",
    "authentik_flows.flow": "flows/instances",
    "authentik_stages_identification.identificationstage": "stages/identification",
    "authentik_stages_password.passwordstage": "stages/password",
    "authentik_stages_user_login.userloginstage": "stages/user_login",
    "authentik_stages_authenticator_validate.authenticatorvalidatestage": "stages/authenticator/validate",
}


def _purge_ghost_objects(
    session: requests.Session, api_root: str, yaml_path: Path
) -> None:
    """
    Before deploying a blueprint, find and delete any objects that exist in
    Authentik with the same *name* as entries in the blueprint but with a
    different PK.  These are leftovers from failed validation runs.

    Only objects whose model maps to a known API collection are handled.
    Objects whose PK already matches the blueprint are left untouched.
    """
    try:
        data = yaml.load(yaml_path.read_text(encoding="utf-8"), Loader=_AuthentikYamlLoader)
    except yaml.YAMLError as exc:
        log.warning("[%s] Cannot parse YAML for cleanup: %s", yaml_path.name, exc)
        return

    for entry in data.get("entries", []):
        model = entry.get("model", "")
        api_path = _MODEL_TO_API.get(model)
        if not api_path:
            continue

        identifiers = entry.get("identifiers", {})
        blueprint_pk = identifiers.get("pk")
        name = (entry.get("attrs") or {}).get("name") or identifiers.get("name") or identifiers.get("slug")
        if not name:
            continue

        try:
            resp = session.get(f"{api_root}/{api_path}/", params={"name": name}, timeout=TIMEOUT)
            if not resp.ok:
                continue
            results = resp.json().get("results", [])
        except requests.RequestException:
            continue

        for obj in results:
            existing_pk = obj.get("pk")
            if existing_pk == blueprint_pk:
                continue  # correct PK — leave it alone

            log.warning(
                "[%s] Ghost object found: model=%s name='%s' pk=%s (blueprint expects pk=%s) — deleting.",
                yaml_path.name,
                model,
                name,
                existing_pk,
                blueprint_pk,
            )
            try:
                del_resp = session.delete(
                    f"{api_root}/{api_path}/{existing_pk}/",
                    timeout=TIMEOUT,
                )
                if del_resp.ok or del_resp.status_code == 404:
                    log.info("[%s] Deleted ghost object pk=%s.", yaml_path.name, existing_pk)
                else:
                    log.error(
                        "[%s] Could not delete ghost object pk=%s: %d %s",
                        yaml_path.name,
                        existing_pk,
                        del_resp.status_code,
                        _format_api_error(del_resp),
                    )
            except requests.RequestException as exc:
                log.error("[%s] Error deleting ghost object pk=%s: %s", yaml_path.name, existing_pk, exc)


# ---------------------------------------------------------------------------
# Branding update
# ---------------------------------------------------------------------------

def _extract_flow_slug(yaml_path: Path) -> str | None:
    """
    Return the slug of the first authentik_flows.flow entry in the blueprint.
    Uses _AuthentikYamlLoader so that !KeyOf tags don't cause failures.
    """
    try:
        data = yaml.load(yaml_path.read_text(encoding="utf-8"), Loader=_AuthentikYamlLoader)
        for entry in data.get("entries", []):
            if entry.get("model") == "authentik_flows.flow":
                slug = entry.get("identifiers", {}).get("slug")
                if slug:
                    return slug
    except Exception as exc:
        log.warning("Could not extract flow slug from %s: %s", yaml_path.name, exc)
    return None


def _update_default_brand(session: requests.Session, api_root: str, flow_slug: str) -> None:
    """
    Set the default brand's (or tenant's) authentication flow to `flow_slug`.

    Resolution steps:
      1. Look up the flow by slug via /api/v3/flows/instances/
      2. Find the default brand via /api/v3/core/brands/  (Authentik >= 2023.10)
         or /api/v3/core/tenants/  (older versions)
      3. PATCH the brand with flow_authentication = <flow pk>
    """
    # --- Resolve the flow PK from its slug ---
    log.info("[branding] Looking up flow with slug '%s' …", flow_slug)
    try:
        resp = session.get(f"{api_root}/flows/instances/", params={"slug": flow_slug}, timeout=TIMEOUT)
        resp.raise_for_status()
    except requests.RequestException as exc:
        log.error("[branding] Failed to query flows API: %s", exc)
        return

    flows = resp.json().get("results", [])
    if not flows:
        log.error(
            "[branding] Flow with slug '%s' not found – has the blueprint been applied successfully?",
            flow_slug,
        )
        return

    flow_pk = flows[0]["pk"]
    flow_name = flows[0].get("name", flow_slug)
    log.info("[branding] Found flow '%s' (pk=%s).", flow_name, flow_pk)

    # --- Find and update the default brand / tenant ---
    for resource in ("brands", "tenants"):
        try:
            list_resp = session.get(f"{api_root}/core/{resource}/", timeout=TIMEOUT)
        except requests.RequestException as exc:
            log.warning("[branding] Could not query %s: %s", resource, exc)
            continue

        if list_resp.status_code == 404:
            continue  # endpoint doesn't exist in this Authentik version

        if not list_resp.ok:
            log.warning("[branding] %s returned %d – skipping.", resource, list_resp.status_code)
            continue

        items = list_resp.json().get("results", [])
        if not items:
            log.warning("[branding] No %s found.", resource)
            continue

        # Prefer the item flagged as default; fall back to the first entry.
        target = next((b for b in items if b.get("default")), items[0])
        # Authentik brands use `brand_uuid`, tenants use `tenant_uuid`; both
        # also expose a generic `pk` in some versions — try all variants.
        target_pk = (
            target.get("pk")
            or target.get("brand_uuid")
            or target.get("tenant_uuid")
        )
        if not target_pk:
            log.error(
                "[branding] Cannot determine PK for %s object: %s",
                resource[:-1],
                list(target.keys()),
            )
            continue
        domain = target.get("domain") or target.get("name") or target_pk

        log.info("[branding] Updating %s '%s' → flow_authentication = '%s' …", resource[:-1], domain, flow_name)

        try:
            patch_resp = session.patch(
                f"{api_root}/core/{resource}/{target_pk}/",
                json={"flow_authentication": flow_pk},
                timeout=TIMEOUT,
            )
        except requests.RequestException as exc:
            log.error("[branding] PATCH failed: %s", exc)
            return

        if not patch_resp.ok:
            log.error("[branding] Failed to update %s: %s", resource[:-1], _format_api_error(patch_resp))
            return

        log.info(
            "[branding] Default %s '%s' now uses authentication flow '%s'.",
            resource[:-1],
            domain,
            flow_name,
        )
        return

    log.error("[branding] Could not find a brands or tenants endpoint – branding not updated.")


# ---------------------------------------------------------------------------
# Core deploy logic
# ---------------------------------------------------------------------------

def deploy_blueprint(session: requests.Session, api_root: str, yaml_path: Path) -> bool:
    """
    Deploy a single blueprint file (upsert + apply).
    Returns True on success, False on failure.
    """
    name = _extract_name(yaml_path)
    content = yaml_path.read_text(encoding="utf-8")
    log.info("[%s] Deploying blueprint '%s' …", yaml_path.name, name)

    payload = {"name": name, "content": content, "enabled": True}

    try:
        existing = _find_existing(session, api_root, name)

        if existing:
            pk = existing["pk"]
            log.info("[%s] Found existing instance (pk=%s) – updating.", yaml_path.name, pk)
            resp = session.put(f"{api_root}/managed/blueprints/{pk}/", json=payload, timeout=TIMEOUT)
        else:
            log.info("[%s] No existing instance – creating.", yaml_path.name)
            resp = session.post(f"{api_root}/managed/blueprints/", json=payload, timeout=TIMEOUT)

        if resp.status_code in (400, 401, 403):
            detail = _format_api_error(resp)
            log.error("[%s] API error %d: %s", yaml_path.name, resp.status_code, detail)
            if resp.status_code == 400 and "already exists" in detail:
                log.error(
                    "[%s] Ghost objects from a failed Authentik validation are still present "
                    "(the automatic cleanup above may not cover all models).\n"
                    "  Check Admin → Customization → Policies and Admin → Flows → Stages "
                    "for objects whose names match the blueprint entries, then re-run.",
                    yaml_path.name,
                )
            return False

        resp.raise_for_status()
        instance = resp.json()
        pk = instance["pk"]
        log.info("[%s] Instance saved (pk=%s, status=%s).", yaml_path.name, pk, instance.get("status"))

    except requests.HTTPError as exc:
        log.error("[%s] HTTP error during save: %s", yaml_path.name, exc)
        return False
    except requests.ConnectionError as exc:
        log.error("[%s] Connection error: %s", yaml_path.name, exc)
        return False

    # Apply the blueprint
    try:
        log.info("[%s] Applying blueprint …", yaml_path.name)
        apply_resp = session.post(f"{api_root}/managed/blueprints/{pk}/apply/", timeout=TIMEOUT)

        if apply_resp.status_code in (400, 401, 403):
            log.error(
                "[%s] Apply error %d: %s",
                yaml_path.name,
                apply_resp.status_code,
                _format_api_error(apply_resp),
            )
            return False

        apply_resp.raise_for_status()
        log.info("[%s] Applied successfully (status=%s).", yaml_path.name, apply_resp.json().get("status"))
        return True

    except requests.HTTPError as exc:
        log.error("[%s] HTTP error during apply: %s", yaml_path.name, exc)
        return False
    except requests.ConnectionError as exc:
        log.error("[%s] Connection error during apply: %s", yaml_path.name, exc)
        return False


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    authentik_url, token = _resolve_credentials()
    api_root = f"{authentik_url}{API_BASE}"

    blueprint_files = sorted(BLUEPRINTS_DIR.glob("**/*.yaml")) + sorted(BLUEPRINTS_DIR.glob("**/*.yml"))

    if not blueprint_files:
        log.warning("No .yaml/.yml files found in %s – nothing to deploy.", BLUEPRINTS_DIR)
        sys.exit(0)

    log.info("Found %d blueprint file(s) in %s.", len(blueprint_files), BLUEPRINTS_DIR)
    log.info("Target Authentik: %s", authentik_url)

    session = _session(token)
    _verify_token(session, api_root)

    # First pass — clean up ghost objects before each deploy
    results: dict[str, bool] = {}
    for bp_file in blueprint_files:
        _purge_ghost_objects(session, api_root, bp_file)
        results[bp_file.name] = deploy_blueprint(session, api_root, bp_file)

    # Retry failed blueprints once — handles dependency-ordering issues where
    # blueprint A references an object created by blueprint B deployed later.
    # Ghost cleanup runs again because the first-pass deploy may have created
    # new leftover objects from a failed validation.
    first_pass_failed = [f for f in blueprint_files if not results[f.name]]
    if first_pass_failed:
        log.info(
            "Retrying %d failed blueprint(s) in case of unresolved dependencies …",
            len(first_pass_failed),
        )
        for bp_file in first_pass_failed:
            _purge_ghost_objects(session, api_root, bp_file)
            results[bp_file.name] = deploy_blueprint(session, api_root, bp_file)

    succeeded = [n for n, ok in results.items() if ok]
    failed = [n for n, ok in results.items() if not ok]

    log.info("=" * 60)
    log.info("Deployment summary: %d succeeded, %d failed.", len(succeeded), len(failed))
    for name in succeeded:
        log.info("  OK    %s", name)
    for name in failed:
        log.error("  FAIL  %s", name)

    # Update default brand only when the auth-flow blueprint was deployed successfully.
    auth_blueprint_path = BLUEPRINTS_DIR / _AUTH_FLOW_BLUEPRINT
    if results.get(_AUTH_FLOW_BLUEPRINT) and auth_blueprint_path.exists():
        log.info("=" * 60)
        flow_slug = _extract_flow_slug(auth_blueprint_path)
        if flow_slug:
            _update_default_brand(session, api_root, flow_slug)
        else:
            log.warning(
                "Could not determine flow slug from %s; skipping branding update.",
                _AUTH_FLOW_BLUEPRINT,
            )

    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
