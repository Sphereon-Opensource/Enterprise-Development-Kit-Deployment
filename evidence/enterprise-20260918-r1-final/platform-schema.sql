--
-- PostgreSQL database dump
--

\restrict 62ZWUIk87rfRU3Pe43oajfLWMbPWoDfKX6UU2QC2BcZfeRQWfi9txShgGwzEoVN

-- Dumped from database version 16.15
-- Dumped by pg_dump version 16.15

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: oauth_signing_key_advance_all_revisions(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.oauth_signing_key_advance_all_revisions() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE oauth_signing_key_revision
    SET revision = revision + 1;
    RETURN NULL;
END
$$;


--
-- Name: oauth_signing_key_advance_revision(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.oauth_signing_key_advance_revision() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    affected_tenant TEXT;
BEGIN
    IF TG_OP = 'UPDATE' AND OLD.tenant_id <> NEW.tenant_id THEN
        RAISE EXCEPTION 'oauth_signing_key tenant_id is immutable';
    END IF;

    IF TG_OP = 'DELETE' THEN
        affected_tenant := OLD.tenant_id;
    ELSE
        affected_tenant := NEW.tenant_id;
    END IF;

    INSERT INTO oauth_signing_key_revision(tenant_id, revision)
    VALUES (affected_tenant, 1)
    ON CONFLICT (tenant_id) DO UPDATE
        SET revision = oauth_signing_key_revision.revision + 1;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END
$$;


--
-- Name: secret_management_bump_policy_parent(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_bump_policy_parent() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_TABLE_NAME='global_tenant_secret_policy_provider_type' THEN
    UPDATE global_tenant_secret_policy
       SET version=version+1,
           updated_at=(EXTRACT(EPOCH FROM clock_timestamp())*1000)::BIGINT
     WHERE policy_key='global';
  ELSE
    UPDATE tenant_secret_policy_override
       SET version=version+1,
           updated_at=(EXTRACT(EPOCH FROM clock_timestamp())*1000)::BIGINT
     WHERE tenant_id=COALESCE(NEW.tenant_id,OLD.tenant_id);
  END IF;
  RETURN COALESCE(NEW, OLD);
END
$$;


--
-- Name: secret_management_generation_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_generation_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'SECRET_MATERIAL_GENERATION_IMMUTABLE';
END
$$;


--
-- Name: secret_management_guard_assignment_eligibility(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_guard_assignment_eligibility() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE d secret_provider_definition%ROWTYPE;
DECLARE r secret_provider_revision%ROWTYPE;
DECLARE binding_count INTEGER;
DECLARE offering_count INTEGER;
DECLARE read_count INTEGER;
DECLARE write_count INTEGER;
DECLARE operation_capability_count INTEGER;
DECLARE total_capability_count INTEGER;
DECLARE isolation_count INTEGER;
BEGIN
  IF TG_OP='UPDATE'
     AND OLD.lifecycle_state='ACTIVE'
     AND NEW.lifecycle_state<>'ACTIVE'
     AND EXISTS (
       SELECT 1
         FROM system_credential_transition_material material
         JOIN system_credential_transition pending_transition
           ON pending_transition.operation_id=material.operation_id
        WHERE material.storage_assignment_id=OLD.assignment_id
          AND pending_transition.operation_phase='PREPARED'
          AND material.lifecycle_state IN ('STAGED','PROVIDER_WRITTEN')
     ) THEN
    RAISE EXCEPTION 'SYSTEM_CREDENTIAL_ASSIGNMENT_HAS_NONTERMINAL_MATERIAL';
  END IF;
  SELECT * INTO d FROM secret_provider_definition
   WHERE definition_id=NEW.definition_id AND owner_scope=NEW.provider_owner_scope;
  SELECT * INTO r FROM secret_provider_revision
   WHERE definition_id=NEW.definition_id AND revision=NEW.revision;
  SELECT COUNT(*) INTO write_count FROM secret_provider_revision_capability
   WHERE definition_id=NEW.definition_id AND revision=NEW.revision AND capability='WRITE';
  SELECT COUNT(*) INTO read_count FROM secret_provider_revision_capability
   WHERE definition_id=NEW.definition_id AND revision=NEW.revision AND capability='READ';
  SELECT COUNT(*) INTO operation_capability_count FROM secret_provider_revision_capability
   WHERE definition_id=NEW.definition_id AND revision=NEW.revision
     AND capability IN ('READ','WRITE','DELETE');
  SELECT COUNT(*) INTO total_capability_count FROM secret_provider_revision_capability
   WHERE definition_id=NEW.definition_id AND revision=NEW.revision;
  SELECT COUNT(*) INTO isolation_count FROM secret_provider_revision_capability
   WHERE definition_id=NEW.definition_id AND revision=NEW.revision
     AND capability='BACKEND_TENANT_ISOLATION';
  IF d.definition_id IS NULL OR r.definition_id IS NULL
     OR d.lifecycle_state NOT IN ('READY','ACTIVE')
     OR r.lifecycle_state NOT IN ('READY','ACTIVE')
     OR r.owner_scope<>d.owner_scope THEN
    RAISE EXCEPTION 'SECRET_PROVIDER_ASSIGNMENT_NOT_ELIGIBLE';
  END IF;
  IF NEW.assignment_role='PLATFORM_STORAGE' THEN
    IF d.owner_kind<>'PLATFORM'
       OR NEW.consumer_tenant_id<>'__platform__'
       OR NEW.tenant_binding_id IS NOT NULL
       OR NOT (
         (
           d.role='PLATFORM_STORAGE'
           AND r.provider_type NOT IN ('ENVIRONMENT','KUBERNETES_MOUNT')
           AND operation_capability_count=3
         )
         OR
         (
           d.role='DEPLOYMENT_SOURCE'
           AND r.provider_type IN ('ENVIRONMENT','KUBERNETES_MOUNT')
           AND r.isolation_mode='READ_ONLY_DEPLOYMENT'
           AND read_count=1
           AND write_count=0
           AND total_capability_count=1
         )
       ) THEN
      RAISE EXCEPTION 'SECRET_PROVIDER_ASSIGNMENT_NOT_ELIGIBLE';
    END IF;
  ELSIF NEW.tenant_binding_id IS NULL THEN
    IF d.owner_kind<>'TENANT' OR d.role<>'TENANT_MANAGED'
       OR d.owner_scope<>NEW.consumer_tenant_id
       OR r.provider_type IN ('ENVIRONMENT','KUBERNETES_MOUNT')
       OR NOT (
         operation_capability_count=3
         OR (
           read_count=1
           AND write_count=0
           AND total_capability_count=1
         )
       ) THEN
      RAISE EXCEPTION 'SECRET_PROVIDER_ASSIGNMENT_NOT_ELIGIBLE';
    END IF;
  ELSE
    SELECT COUNT(*) INTO binding_count FROM tenant_provider_binding b
     WHERE b.tenant_id=NEW.consumer_tenant_id
       AND b.binding_id=NEW.tenant_binding_id
       AND b.definition_id=NEW.definition_id
       AND b.provider_revision=NEW.revision
       AND b.lifecycle_state IN ('READY','ACTIVE');
    SELECT COUNT(*) INTO offering_count
      FROM tenant_provider_binding b
      JOIN platform_secret_provider_offering o
        ON o.offering_id=b.offering_id
       AND o.definition_id=b.definition_id
       AND o.published_revision=b.provider_revision
     WHERE b.tenant_id=NEW.consumer_tenant_id
       AND b.binding_id=NEW.tenant_binding_id
       AND o.enabled=TRUE AND o.lifecycle_state='ACTIVE';
    IF d.owner_kind<>'PLATFORM' OR d.role<>'PLATFORM_OFFERING'
       OR r.provider_type IN ('ENVIRONMENT','KUBERNETES_MOUNT')
       OR NOT (
         operation_capability_count=3
         OR (
           read_count=1
           AND write_count=0
           AND operation_capability_count=1
           AND total_capability_count=2
         )
       )
       OR binding_count<>1 OR offering_count<>1 OR isolation_count<>1 THEN
      RAISE EXCEPTION 'SECRET_PROVIDER_ASSIGNMENT_NOT_ELIGIBLE';
    END IF;
  END IF;
  RETURN NEW;
END
$$;


--
-- Name: secret_management_guard_authority_grant(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_guard_authority_grant() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  manifest_state TEXT;
BEGIN
  IF TG_OP='INSERT' THEN
    SELECT lifecycle_state INTO manifest_state
      FROM secret_authority_manifest
     WHERE generation=NEW.manifest_generation;
    IF manifest_state<>'ACTIVE' THEN
      RAISE EXCEPTION 'SECRET_AUTHORITY_AUTHORITY_MANIFEST_INACTIVE';
    END IF;
    RETURN NEW;
  END IF;
  IF TG_OP='DELETE' OR
     NEW.manifest_generation IS DISTINCT FROM OLD.manifest_generation OR
     NEW.effective_actor_id IS DISTINCT FROM OLD.effective_actor_id OR
     NEW.authenticated_tenant_id IS DISTINCT FROM OLD.authenticated_tenant_id OR
     NEW.target_tenant_scope IS DISTINCT FROM OLD.target_tenant_scope OR
     NEW.authority_scope IS DISTINCT FROM OLD.authority_scope OR
     NEW.operation IS DISTINCT FROM OLD.operation OR
     NEW.created_at IS DISTINCT FROM OLD.created_at OR
     OLD.lifecycle_state<>'ACTIVE' OR NEW.lifecycle_state<>'RETIRED' OR
     NEW.version<>OLD.version+1 OR NEW.retired_at IS NULL THEN
    RAISE EXCEPTION 'SECRET_AUTHORITY_AUTHORITY_IMMUTABLE';
  END IF;
  RETURN NEW;
END
$$;


--
-- Name: secret_management_guard_authority_manifest(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_guard_authority_manifest() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'SECRET_AUTHORITY_AUTHORITY_IMMUTABLE';
  END IF;
  IF TG_OP='UPDATE' AND (
    NEW.generation IS DISTINCT FROM OLD.generation OR
    NEW.manifest_digest IS DISTINCT FROM OLD.manifest_digest OR
    NEW.authority_source IS DISTINCT FROM OLD.authority_source OR
    NEW.activated_at IS DISTINCT FROM OLD.activated_at OR
    OLD.lifecycle_state<>'ACTIVE' OR NEW.lifecycle_state<>'RETIRED' OR
    NEW.version<>OLD.version+1 OR NEW.retired_at IS NULL
  ) THEN
    RAISE EXCEPTION 'SECRET_AUTHORITY_AUTHORITY_IMMUTABLE';
  END IF;
  RETURN NEW;
END
$$;


--
-- Name: secret_management_guard_capability_generation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_guard_capability_generation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  revision_provider TEXT;
  proof_count INTEGER;
BEGIN
  IF TG_OP='UPDATE' AND (
    NEW.tenant_id IS DISTINCT FROM OLD.tenant_id OR
    NEW.binding_id IS DISTINCT FROM OLD.binding_id OR
    NEW.capability_generation IS DISTINCT FROM OLD.capability_generation OR
    NEW.provider_type IS DISTINCT FROM OLD.provider_type OR
    NEW.created_at IS DISTINCT FROM OLD.created_at
  ) THEN
    RAISE EXCEPTION 'SECRET_PROVIDER_CAPABILITY_GENERATION_IMMUTABLE';
  END IF;
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'SECRET_PROVIDER_CAPABILITY_GENERATION_IMMUTABLE';
  END IF;
  SELECT r.provider_type INTO revision_provider
    FROM tenant_provider_binding b
    JOIN secret_provider_revision r
      ON r.definition_id=b.definition_id AND r.revision=b.provider_revision
   WHERE b.tenant_id=NEW.tenant_id AND b.binding_id=NEW.binding_id;
  IF revision_provider IS NULL OR revision_provider<>NEW.provider_type THEN
    RAISE EXCEPTION 'SECRET_PROVIDER_CAPABILITY_PROVIDER_MISMATCH';
  END IF;
  IF NEW.provider_type='AZURE_KEY_VAULT' THEN
    RAISE EXCEPTION 'SECRET_PROVIDER_SHARED_OFFERING_NOT_ELIGIBLE';
  END IF;
  IF NEW.lifecycle_state IN ('READY','ACTIVE') AND
     (TG_OP='INSERT' OR OLD.lifecycle_state NOT IN ('READY','ACTIVE')) THEN
    SELECT
      (SELECT COUNT(*) FROM tenant_provider_isolation_proof_kms
        WHERE tenant_id=NEW.tenant_id AND binding_id=NEW.binding_id
          AND capability_generation=NEW.capability_generation)
      +(SELECT COUNT(*) FROM tenant_provider_isolation_proof_vault
        WHERE tenant_id=NEW.tenant_id AND binding_id=NEW.binding_id
          AND capability_generation=NEW.capability_generation)
      +(SELECT COUNT(*) FROM tenant_provider_isolation_proof_azure
        WHERE tenant_id=NEW.tenant_id AND binding_id=NEW.binding_id
          AND capability_generation=NEW.capability_generation)
      +(SELECT COUNT(*) FROM tenant_provider_isolation_proof_aws
        WHERE tenant_id=NEW.tenant_id AND binding_id=NEW.binding_id
          AND capability_generation=NEW.capability_generation)
      INTO proof_count;
    IF proof_count<>1 THEN
      RAISE EXCEPTION 'SECRET_PROVIDER_ISOLATION_PROOF_REQUIRED';
    END IF;
  END IF;
  RETURN NEW;
END
$$;


--
-- Name: secret_management_guard_capability_material(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_guard_capability_material() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  parent_provider TEXT;
  secret_class TEXT;
  secret_owner TEXT;
  secret_storage_consumer TEXT;
  secret_purpose TEXT;
  secret_assignment_id TEXT;
  different_source_count INTEGER;
BEGIN
  IF TG_OP IN ('UPDATE','DELETE') THEN
    RAISE EXCEPTION 'SECRET_PROVIDER_CAPABILITY_MATERIAL_IMMUTABLE';
  END IF;
  SELECT provider_type INTO parent_provider
    FROM tenant_provider_capability_generation
   WHERE tenant_id=NEW.tenant_id
     AND binding_id=NEW.binding_id
     AND capability_generation=NEW.capability_generation;
  IF parent_provider IS NULL THEN
    RAISE EXCEPTION 'SECRET_PROVIDER_CAPABILITY_GENERATION_REQUIRED';
  END IF;
  IF (parent_provider='VAULT' AND NEW.credential_field NOT IN ('roleId','secretId'))
     OR (parent_provider='AWS_SECRETS_MANAGER' AND NEW.credential_field<>'externalId')
     OR parent_provider IN ('KMS','AZURE_KEY_VAULT') THEN
    RAISE EXCEPTION 'SECRET_PROVIDER_CAPABILITY_FIELD_NOT_PERMITTED';
  END IF;
  SELECT record_class, owner_tenant_id, storage_consumer_tenant_id, purpose, assignment_id
    INTO secret_class, secret_owner, secret_storage_consumer, secret_purpose, secret_assignment_id
    FROM secret_record
   WHERE secret_id=NEW.capability_secret_id
     AND owner_tenant_id=NEW.tenant_id
     AND generation=NEW.material_generation;
  IF secret_class IS NULL
     OR secret_class<>'TENANT_CAPABILITY'
     OR secret_owner<>NEW.tenant_id
     OR secret_storage_consumer<>'__platform__'
     OR secret_purpose<>('tenant-provider-capability:' || NEW.credential_field) THEN
    RAISE EXCEPTION 'SECRET_PROVIDER_CAPABILITY_MATERIAL_SCOPE_INVALID';
  END IF;
  SELECT COUNT(*) INTO different_source_count
    FROM tenant_provider_capability_material m
    JOIN secret_record r
      ON r.secret_id=m.capability_secret_id
     AND r.owner_tenant_id=m.tenant_id
     AND r.generation=m.material_generation
   WHERE m.tenant_id=NEW.tenant_id
     AND m.binding_id=NEW.binding_id
     AND m.capability_generation=NEW.capability_generation
     AND r.assignment_id<>secret_assignment_id;
  IF different_source_count<>0 THEN
    RAISE EXCEPTION 'SECRET_PROVIDER_CAPABILITY_MATERIAL_SOURCE_MISMATCH';
  END IF;
  RETURN NEW;
END
$$;


--
-- Name: secret_management_guard_configuration_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_guard_configuration_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    d TEXT;
    r BIGINT;
    revision_state TEXT;
BEGIN
    d := COALESCE(NEW.definition_id, OLD.definition_id);
    r := COALESCE(NEW.revision, OLD.revision);
    SELECT lifecycle_state INTO revision_state
      FROM secret_provider_revision
     WHERE definition_id = d AND revision = r;
    IF revision_state IN ('READY', 'ACTIVE') THEN
        RAISE EXCEPTION 'SECRET_PROVIDER_READY_CONFIGURATION_IMMUTABLE';
    END IF;
    RETURN COALESCE(NEW, OLD);
END
$$;


--
-- Name: secret_management_guard_credential_binding(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_guard_credential_binding() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE provider_role TEXT;
BEGIN
  SELECT d.role INTO provider_role
    FROM secret_provider_definition d
   WHERE d.definition_id=NEW.definition_id;
  IF (provider_role IN ('PLATFORM_STORAGE','PLATFORM_OFFERING') AND NEW.storage_tier<>'BOOTSTRAP')
     OR (provider_role='TENANT_MANAGED' AND NEW.storage_tier<>'PLATFORM')
     OR provider_role='DEPLOYMENT_SOURCE' THEN
    RAISE EXCEPTION 'SECRET_PROVIDER_CREDENTIAL_STORAGE_TIER_INVALID';
  END IF;
  RETURN NEW;
END
$$;


--
-- Name: secret_management_guard_credential_material(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_guard_credential_material() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  expected_tier TEXT;
  binding_generation BIGINT;
  binding_configured BOOLEAN;
  definition_owner TEXT;
  material_generation_actual BIGINT;
  material_owner_actual TEXT;
  material_storage_consumer TEXT;
  material_class TEXT;
BEGIN
  IF TG_OP IN ('UPDATE','DELETE') THEN
    RAISE EXCEPTION 'SECRET_PROVIDER_CREDENTIAL_MATERIAL_IMMUTABLE';
  END IF;
  SELECT b.storage_tier, b.generation, b.configured, d.owner_scope
    INTO expected_tier, binding_generation, binding_configured, definition_owner
    FROM secret_provider_credential_binding b
    JOIN secret_provider_definition d ON d.definition_id=b.definition_id
   WHERE b.definition_id=NEW.definition_id
     AND b.revision=NEW.revision
     AND b.credential_field=NEW.credential_field;
  IF expected_tier IS NULL THEN
    RAISE EXCEPTION 'SECRET_PROVIDER_CREDENTIAL_MATERIAL_BINDING_INVALID';
  END IF;
  IF NEW.material_generation<>binding_generation THEN
    RAISE EXCEPTION 'SECRET_PROVIDER_CREDENTIAL_MATERIAL_GENERATION_INVALID';
  END IF;
  IF TG_TABLE_NAME='secret_provider_bootstrap_credential_material' THEN
    IF expected_tier<>'BOOTSTRAP' THEN
      RAISE EXCEPTION 'SECRET_PROVIDER_CREDENTIAL_MATERIAL_TIER_INVALID';
    END IF;
    SELECT generation INTO material_generation_actual
      FROM platform_bootstrap_credential
     WHERE credential_id=NEW.material_credential_id;
    IF material_generation_actual IS NULL
       OR material_generation_actual<>NEW.material_generation THEN
      RAISE EXCEPTION 'SECRET_PROVIDER_CREDENTIAL_MATERIAL_GENERATION_INVALID';
    END IF;
  ELSE
    IF expected_tier<>'PLATFORM' OR definition_owner='__platform__' THEN
      RAISE EXCEPTION 'SECRET_PROVIDER_CREDENTIAL_MATERIAL_TIER_INVALID';
    END IF;
    SELECT generation, owner_tenant_id, storage_consumer_tenant_id, record_class
      INTO material_generation_actual, material_owner_actual, material_storage_consumer, material_class
      FROM secret_record
     WHERE secret_id=NEW.material_secret_id
       AND owner_tenant_id=NEW.material_owner_tenant_id;
    IF material_generation_actual IS NULL
       OR material_generation_actual<>NEW.material_generation
       OR material_owner_actual<>definition_owner
       OR material_storage_consumer<>'__platform__'
       OR material_class<>'PROVIDER_CREDENTIAL' THEN
      RAISE EXCEPTION 'SECRET_PROVIDER_CREDENTIAL_MATERIAL_SCOPE_INVALID';
    END IF;
  END IF;
  RETURN NEW;
END
$$;


--
-- Name: secret_management_guard_generation_advance(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_guard_generation_advance() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  old_generation BIGINT;
  new_generation BIGINT;
BEGIN
  IF TG_TABLE_NAME='tenant_provider_binding' THEN
    old_generation := OLD.capability_generation;
    new_generation := NEW.capability_generation;
  ELSIF TG_TABLE_NAME='secret_provider_credential_binding' THEN
    old_generation := OLD.generation;
    new_generation := NEW.generation;
  ELSIF TG_TABLE_NAME='platform_bootstrap_credential' THEN
    old_generation := OLD.generation;
    new_generation := NEW.generation;
  ELSIF TG_TABLE_NAME='secret_record' THEN
    old_generation := OLD.generation;
    new_generation := NEW.generation;
  ELSE
    RAISE EXCEPTION 'SECRET_MATERIAL_GENERATION_GUARD_TABLE_INVALID';
  END IF;
  IF new_generation IS DISTINCT FROM old_generation
     AND new_generation<>old_generation+1 THEN
    RAISE EXCEPTION 'SECRET_MATERIAL_GENERATION_MUST_ADVANCE_BY_ONE';
  END IF;
  RETURN NEW;
END
$$;


--
-- Name: secret_management_guard_isolation_proof(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_guard_isolation_proof() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  expected_provider TEXT;
  generation_state TEXT;
  binding_partition TEXT;
BEGIN
  IF TG_OP IN ('UPDATE','DELETE') THEN
    RAISE EXCEPTION 'SECRET_PROVIDER_ISOLATION_PROOF_IMMUTABLE';
  END IF;
  SELECT g.provider_type, g.lifecycle_state, b.opaque_partition
    INTO expected_provider, generation_state, binding_partition
    FROM tenant_provider_capability_generation g
    JOIN tenant_provider_binding b
      ON b.tenant_id=g.tenant_id AND b.binding_id=g.binding_id
   WHERE g.tenant_id=NEW.tenant_id
     AND g.binding_id=NEW.binding_id
     AND g.capability_generation=NEW.capability_generation;
  IF generation_state IS NULL OR generation_state<>'CANDIDATE' THEN
    RAISE EXCEPTION 'SECRET_PROVIDER_ISOLATION_PROOF_STATE_INVALID';
  END IF;
  IF (TG_TABLE_NAME='tenant_provider_isolation_proof_kms' AND expected_provider<>'KMS')
     OR (TG_TABLE_NAME='tenant_provider_isolation_proof_vault' AND expected_provider<>'VAULT')
     OR (TG_TABLE_NAME='tenant_provider_isolation_proof_azure' AND expected_provider<>'AZURE_KEY_VAULT')
     OR (TG_TABLE_NAME='tenant_provider_isolation_proof_aws' AND expected_provider<>'AWS_SECRETS_MANAGER') THEN
    RAISE EXCEPTION 'SECRET_PROVIDER_ISOLATION_PROOF_TYPE_INVALID';
  END IF;
  IF TG_TABLE_NAME='tenant_provider_isolation_proof_vault'
     AND (to_jsonb(NEW)->>'opaque_binding_partition')<>binding_partition THEN
    RAISE EXCEPTION 'SECRET_PROVIDER_VAULT_PARTITION_PROOF_INVALID';
  END IF;
  RETURN NEW;
END
$$;


--
-- Name: secret_management_guard_kms_payload_scope(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_guard_kms_payload_scope() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE d secret_provider_definition%ROWTYPE;
DECLARE r secret_provider_revision%ROWTYPE;
DECLARE binding_count INTEGER;
BEGIN
  SELECT * INTO d FROM secret_provider_definition WHERE definition_id=NEW.definition_id;
  SELECT * INTO r FROM secret_provider_revision
   WHERE definition_id=NEW.definition_id AND revision=NEW.revision;
  IF d.definition_id IS NULL OR r.definition_id IS NULL
     OR r.provider_type<>'KMS'
     OR r.lifecycle_state NOT IN ('READY','ACTIVE') THEN
    RAISE EXCEPTION 'SECRET_KMS_PAYLOAD_SCOPE_INVALID';
  END IF;
  IF NEW.consumer_tenant_id='__platform__' THEN
    IF d.owner_kind<>'PLATFORM' OR d.owner_scope<>'__platform__'
       OR d.role<>'PLATFORM_STORAGE' OR NEW.tenant_binding_id IS NOT NULL THEN
      RAISE EXCEPTION 'SECRET_KMS_PAYLOAD_SCOPE_INVALID';
    END IF;
  ELSIF NEW.tenant_binding_id IS NULL THEN
    IF d.owner_kind<>'TENANT' OR d.owner_scope<>NEW.consumer_tenant_id
       OR d.role<>'TENANT_MANAGED' THEN
      RAISE EXCEPTION 'SECRET_KMS_PAYLOAD_SCOPE_INVALID';
    END IF;
  ELSE
    SELECT COUNT(*) INTO binding_count FROM tenant_provider_binding
     WHERE tenant_id=NEW.consumer_tenant_id
       AND binding_id=NEW.tenant_binding_id
       AND definition_id=NEW.definition_id
       AND provider_revision=NEW.revision
       AND lifecycle_state IN ('READY','ACTIVE','RETAINED');
    IF d.owner_kind<>'PLATFORM' OR d.owner_scope<>'__platform__'
       OR d.role<>'PLATFORM_OFFERING' OR binding_count<>1 THEN
      RAISE EXCEPTION 'SECRET_KMS_PAYLOAD_SCOPE_INVALID';
    END IF;
  END IF;
  RETURN NEW;
END
$$;


--
-- Name: secret_management_guard_kms_resource_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_guard_kms_resource_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'KMS_RESOURCE_MUTATION_IMMUTABLE';
END
$$;


--
-- Name: secret_management_guard_lifecycle_transition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_guard_lifecycle_transition() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.lifecycle_state=OLD.lifecycle_state THEN RETURN NEW; END IF;
  IF NOT (
    (TG_TABLE_NAME IN ('tenant_provider_binding','secret_provider_assignment','secret_record') AND OLD.lifecycle_state='CANDIDATE' AND NEW.lifecycle_state='ACTIVE') OR
    (OLD.lifecycle_state='CANDIDATE' AND NEW.lifecycle_state IN ('READY','FAILED')) OR
    (OLD.lifecycle_state='READY' AND NEW.lifecycle_state IN ('ACTIVE','SUSPENDED','RETIRED','FAILED')) OR
    (OLD.lifecycle_state='ACTIVE' AND NEW.lifecycle_state IN ('SUSPENDED','RETAINED','RETIRED','FAILED')) OR
    (OLD.lifecycle_state='SUSPENDED' AND NEW.lifecycle_state IN ('ACTIVE','RETIRED','FAILED')) OR
    (OLD.lifecycle_state='RETAINED' AND NEW.lifecycle_state IN ('ACTIVE','RETIRED','PURGED')) OR
    (OLD.lifecycle_state='RETIRED' AND NEW.lifecycle_state='PURGED') OR
    (OLD.lifecycle_state='FAILED' AND NEW.lifecycle_state IN ('CANDIDATE','RETIRED','PURGED'))
  ) THEN
    RAISE EXCEPTION 'SECRET_MANAGEMENT_LIFECYCLE_TRANSITION_INVALID';
  END IF;
  RETURN NEW;
END
$$;


--
-- Name: secret_management_guard_offering(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_guard_offering() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    d secret_provider_definition%ROWTYPE;
    r secret_provider_revision%ROWTYPE;
    isolated_count INTEGER;
BEGIN
    SELECT * INTO d FROM secret_provider_definition WHERE definition_id=NEW.definition_id;
    SELECT * INTO r FROM secret_provider_revision
      WHERE definition_id=NEW.definition_id AND revision=NEW.published_revision;
    SELECT COUNT(*) INTO isolated_count FROM secret_provider_revision_capability
      WHERE definition_id=NEW.definition_id AND revision=NEW.published_revision
        AND capability='BACKEND_TENANT_ISOLATION';
    IF d.owner_kind <> 'PLATFORM' OR d.role <> 'PLATFORM_OFFERING'
       OR r.provider_type IN ('ENVIRONMENT','KUBERNETES_MOUNT')
       OR r.lifecycle_state NOT IN ('READY','ACTIVE')
       OR isolated_count <> 1 THEN
        RAISE EXCEPTION 'SECRET_PROVIDER_OFFERING_NOT_ELIGIBLE';
    END IF;
    IF TG_OP='UPDATE' AND pg_trigger_depth() <= 1
       AND NEW.assignment_count IS DISTINCT FROM OLD.assignment_count THEN
        RAISE EXCEPTION 'SECRET_PROVIDER_ASSIGNMENT_COUNT_DERIVED';
    END IF;
    RETURN NEW;
END
$$;


--
-- Name: secret_management_guard_resource_binding(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_guard_resource_binding() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'SECRET_RESOURCE_BINDING_IMMUTABLE';
  END IF;
  IF TG_OP='UPDATE' AND (
    NEW.owner_tenant_id IS DISTINCT FROM OLD.owner_tenant_id OR
    NEW.resource_kind IS DISTINCT FROM OLD.resource_kind OR
    NEW.resource_instance_key IS DISTINCT FROM OLD.resource_instance_key OR
    NEW.credential_slot IS DISTINCT FROM OLD.credential_slot OR
    NEW.binding_generation IS DISTINCT FROM OLD.binding_generation OR
    NEW.secret_id IS DISTINCT FROM OLD.secret_id OR
    NEW.secret_generation IS DISTINCT FROM OLD.secret_generation OR
    NEW.record_class IS DISTINCT FROM OLD.record_class OR
    NEW.provider_definition_id IS DISTINCT FROM OLD.provider_definition_id OR
    NEW.provider_revision IS DISTINCT FROM OLD.provider_revision OR
    NEW.tenant_binding_id IS DISTINCT FROM OLD.tenant_binding_id OR
    NEW.provider_assignment_id IS DISTINCT FROM OLD.provider_assignment_id OR
    NEW.created_at IS DISTINCT FROM OLD.created_at
  ) THEN
    RAISE EXCEPTION 'SECRET_RESOURCE_BINDING_IMMUTABLE';
  END IF;
  IF TG_OP='UPDATE' AND (
    OLD.lifecycle_state<>'ACTIVE' OR NEW.lifecycle_state NOT IN ('RETIRED','FAILED') OR
    NEW.retired_at IS NULL
  ) THEN
    RAISE EXCEPTION 'SECRET_RESOURCE_BINDING_TRANSITION_INVALID';
  END IF;
  RETURN NEW;
END
$$;


--
-- Name: secret_management_guard_retirement_dependencies(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_guard_retirement_dependencies() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE dependency_count BIGINT;
BEGIN
  IF NEW.lifecycle_state<>'RETIRED' OR OLD.lifecycle_state='RETIRED' THEN
    RETURN NEW;
  END IF;
  IF TG_TABLE_NAME='secret_provider_definition' THEN
    SELECT
      (SELECT COUNT(*) FROM secret_provider_assignment
        WHERE definition_id=NEW.definition_id AND lifecycle_state NOT IN ('RETIRED','PURGED')) +
      (SELECT COUNT(*) FROM platform_secret_provider_offering
        WHERE definition_id=NEW.definition_id AND lifecycle_state NOT IN ('RETIRED','PURGED')) +
      (SELECT COUNT(*) FROM tenant_provider_binding
        WHERE definition_id=NEW.definition_id AND lifecycle_state NOT IN ('RETIRED','PURGED')) +
      (SELECT COUNT(*) FROM secret_preflight_journal
        WHERE target_definition_id=NEW.definition_id
          AND operation_state NOT IN ('COMMITTED','ROLLED_BACK','PURGED','FAILED','CANCELLED')) +
      (SELECT COUNT(*) FROM secret_migration_journal
        WHERE target_definition_id=NEW.definition_id
          AND operation_state NOT IN ('ROLLED_BACK','PURGED','FAILED','CANCELLED')) +
      (SELECT COUNT(*) FROM secret_migration_journal m
        JOIN secret_provider_assignment a
          ON a.assignment_id=m.source_assignment_id
         AND a.consumer_tenant_id=m.consumer_tenant_id
        WHERE a.definition_id=NEW.definition_id
          AND operation_state NOT IN ('ROLLED_BACK','PURGED','FAILED','CANCELLED'))
    INTO dependency_count;
  ELSE
    SELECT
      (SELECT COUNT(*) FROM secret_provider_assignment
        WHERE definition_id=NEW.definition_id AND revision=NEW.revision
          AND lifecycle_state NOT IN ('RETIRED','PURGED')) +
      (SELECT COUNT(*) FROM platform_secret_provider_offering
        WHERE definition_id=NEW.definition_id AND published_revision=NEW.revision
          AND lifecycle_state NOT IN ('RETIRED','PURGED')) +
      (SELECT COUNT(*) FROM tenant_provider_binding
        WHERE definition_id=NEW.definition_id AND provider_revision=NEW.revision
          AND lifecycle_state NOT IN ('RETIRED','PURGED')) +
      (SELECT COUNT(*) FROM secret_preflight_journal
        WHERE target_definition_id=NEW.definition_id AND target_revision=NEW.revision
          AND operation_state NOT IN ('COMMITTED','ROLLED_BACK','PURGED','FAILED','CANCELLED')) +
      (SELECT COUNT(*) FROM secret_migration_journal
        WHERE target_definition_id=NEW.definition_id AND target_revision=NEW.revision
          AND operation_state NOT IN ('ROLLED_BACK','PURGED','FAILED','CANCELLED')) +
      (SELECT COUNT(*) FROM secret_migration_journal m
        JOIN secret_provider_assignment a
          ON a.assignment_id=m.source_assignment_id
         AND a.consumer_tenant_id=m.consumer_tenant_id
        WHERE a.definition_id=NEW.definition_id AND a.revision=NEW.revision
          AND operation_state NOT IN ('ROLLED_BACK','PURGED','FAILED','CANCELLED')) +
      (SELECT COUNT(*) FROM secret_credential_rotation_journal
        WHERE definition_id=NEW.definition_id AND revision=NEW.revision
          AND operation_state NOT IN ('COMMITTED','ROLLED_BACK','PURGED','FAILED','CANCELLED'))
    INTO dependency_count;
  END IF;
  IF dependency_count<>0 THEN
    RAISE EXCEPTION 'SECRET_PROVIDER_RETIREMENT_DEPENDENCY_CONFLICT';
  END IF;
  RETURN NEW;
END
$$;


--
-- Name: secret_management_guard_revision(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_guard_revision() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE definition_role TEXT;
DECLARE definition_owner_kind TEXT;
BEGIN
    IF TG_OP='UPDATE' AND OLD.lifecycle_state IN ('READY', 'ACTIVE') AND (
        NEW.definition_id IS DISTINCT FROM OLD.definition_id OR
        NEW.revision IS DISTINCT FROM OLD.revision OR
        NEW.owner_scope IS DISTINCT FROM OLD.owner_scope OR
        NEW.provider_type IS DISTINCT FROM OLD.provider_type OR
        NEW.isolation_mode IS DISTINCT FROM OLD.isolation_mode OR
        NEW.addressing_policy_id IS DISTINCT FROM OLD.addressing_policy_id OR
        NEW.created_at IS DISTINCT FROM OLD.created_at
    ) THEN
        RAISE EXCEPTION 'SECRET_PROVIDER_READY_REVISION_IMMUTABLE';
    END IF;
    SELECT role, owner_kind INTO definition_role, definition_owner_kind
      FROM secret_provider_definition
     WHERE definition_id=NEW.definition_id AND owner_scope=NEW.owner_scope;
    IF definition_role IS NULL THEN
        RAISE EXCEPTION 'SECRET_PROVIDER_REVISION_DEFINITION_INVALID';
    END IF;
    -- A tenant-owned revision is either an external store the tenant brings, or the
    -- product-managed KMS resource the server clones for it from a platform offering.
    -- The clone is minted below the command boundary and carries the TENANT_MANAGED role,
    -- so a tenant still cannot author a KMS revision of any other role for itself.
    IF NEW.owner_scope <> '__platform__'
       AND NEW.provider_type NOT IN ('VAULT', 'AZURE_KEY_VAULT', 'AWS_SECRETS_MANAGER')
       AND NOT (NEW.provider_type='KMS' AND definition_role='TENANT_MANAGED') THEN
        RAISE EXCEPTION 'SECRET_PROVIDER_TENANT_TYPE_NOT_PERMITTED';
    END IF;
    IF definition_role='PLATFORM_STORAGE'
       AND NEW.provider_type IN ('ENVIRONMENT','KUBERNETES_MOUNT') THEN
        RAISE EXCEPTION 'SECRET_PROVIDER_PLATFORM_STORAGE_TYPE_NOT_PERMITTED';
    END IF;
    IF NEW.provider_type IN ('ENVIRONMENT','KUBERNETES_MOUNT')
       AND (definition_role<>'DEPLOYMENT_SOURCE' OR definition_owner_kind<>'PLATFORM') THEN
        RAISE EXCEPTION 'SECRET_PROVIDER_DEPLOYMENT_SOURCE_ROLE_REQUIRED';
    END IF;
    IF definition_role='DEPLOYMENT_SOURCE'
       AND NEW.provider_type NOT IN ('ENVIRONMENT','KUBERNETES_MOUNT') THEN
        RAISE EXCEPTION 'SECRET_PROVIDER_DEPLOYMENT_SOURCE_TYPE_REQUIRED';
    END IF;
    RETURN NEW;
END
$$;


--
-- Name: secret_management_guard_server_kms_resource_offering(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_guard_server_kms_resource_offering() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'SERVER_KMS_RESOURCE_OFFERING_IMMUTABLE';
END
$$;


--
-- Name: secret_management_guard_system_credential_record(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_guard_system_credential_record() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP='INSERT' THEN
    IF NEW.record_class='SYSTEM_CREDENTIAL'
       AND (
         NEW.lifecycle_state<>'CANDIDATE'
         OR NEW.generation<>1
         OR NEW.version<>1
       ) THEN
      RAISE EXCEPTION 'SYSTEM_CREDENTIAL_RECORD_MUST_START_CANDIDATE';
    END IF;
    RETURN NEW;
  END IF;
  IF OLD.record_class<>'SYSTEM_CREDENTIAL' THEN
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'SYSTEM_CREDENTIAL_RECORD_IMMUTABLE';
  END IF;
  IF NEW.secret_id IS NOT DISTINCT FROM OLD.secret_id
     AND NEW.owner_tenant_id IS NOT DISTINCT FROM OLD.owner_tenant_id
     AND NEW.storage_consumer_tenant_id IS NOT DISTINCT FROM OLD.storage_consumer_tenant_id
     AND NEW.record_class IS NOT DISTINCT FROM OLD.record_class
     AND NEW.purpose IS NOT DISTINCT FROM OLD.purpose
     AND NEW.generation=OLD.generation
     AND NEW.lifecycle_state=OLD.lifecycle_state
     AND NEW.assignment_id IS DISTINCT FROM OLD.assignment_id
     AND NEW.version=OLD.version+1
     AND NEW.created_at IS NOT DISTINCT FROM OLD.created_at
     AND NEW.updated_at>=OLD.updated_at
     AND EXISTS (
       SELECT 1
         FROM system_credential_transition pending_transition
         JOIN secret_provider_assignment assignment
           ON assignment.assignment_id=NEW.assignment_id
          AND assignment.consumer_tenant_id='__platform__'
         WHERE pending_transition.owner_tenant_id=OLD.owner_tenant_id
           AND pending_transition.secret_id=OLD.secret_id
           AND pending_transition.operation_kind='CREATE'
           AND pending_transition.operation_phase='PREPARED'
           AND pending_transition.expected_generation=0
           AND pending_transition.target_generation=OLD.generation
           AND OLD.lifecycle_state='CANDIDATE'
           AND assignment.assignment_role='PLATFORM_STORAGE'
           AND assignment.lifecycle_state='ACTIVE'
     ) THEN
    RETURN NEW;
  END IF;
  IF NEW.secret_id IS DISTINCT FROM OLD.secret_id
     OR NEW.owner_tenant_id IS DISTINCT FROM OLD.owner_tenant_id
     OR NEW.storage_consumer_tenant_id IS DISTINCT FROM OLD.storage_consumer_tenant_id
     OR NEW.record_class IS DISTINCT FROM OLD.record_class
     OR NEW.purpose IS DISTINCT FROM OLD.purpose
     OR NEW.created_at IS DISTINCT FROM OLD.created_at
     OR NEW.updated_at<OLD.updated_at THEN
    RAISE EXCEPTION 'SYSTEM_CREDENTIAL_RECORD_IMMUTABLE';
  END IF;
  IF OLD.lifecycle_state='CANDIDATE'
     AND NEW.lifecycle_state='ACTIVE'
     AND NEW.generation=OLD.generation
     AND NEW.assignment_id IS NOT DISTINCT FROM OLD.assignment_id
     AND NEW.version=OLD.version+1
     AND EXISTS (
       SELECT 1 FROM system_credential_transition pending_transition
        WHERE pending_transition.owner_tenant_id=OLD.owner_tenant_id
          AND pending_transition.secret_id=OLD.secret_id
          AND pending_transition.operation_kind='CREATE'
          AND pending_transition.operation_phase='PREPARED'
          AND pending_transition.target_generation=NEW.generation
     ) THEN
    RETURN NEW;
  END IF;
  IF OLD.lifecycle_state='ACTIVE'
     AND NEW.lifecycle_state='ACTIVE'
     AND NEW.generation=OLD.generation+1
     AND NEW.version=OLD.version+1
     AND EXISTS (
       SELECT 1
         FROM system_credential_transition pending_transition
         JOIN system_credential_transition_material material
           ON material.operation_id=pending_transition.operation_id
        WHERE pending_transition.owner_tenant_id=OLD.owner_tenant_id
          AND pending_transition.secret_id=OLD.secret_id
          AND pending_transition.operation_kind='ROTATE'
          AND pending_transition.operation_phase='PREPARED'
          AND pending_transition.expected_generation=OLD.generation
          AND pending_transition.target_generation=NEW.generation
          AND material.fence=pending_transition.fence
          AND material.target_generation=NEW.generation
          AND material.storage_assignment_id=NEW.assignment_id
          AND material.lifecycle_state='CONSUMED'
     ) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'SYSTEM_CREDENTIAL_RECORD_TRANSITION_INVALID';
END
$$;


--
-- Name: secret_management_guard_system_credential_reference(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_guard_system_credential_reference() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP='INSERT' THEN
    IF NEW.lifecycle_state<>'CANDIDATE' OR NEW.generation<>1 OR NEW.version<>1 THEN
      RAISE EXCEPTION 'SYSTEM_CREDENTIAL_REFERENCE_MUST_START_CANDIDATE';
    END IF;
    RETURN NEW;
  END IF;
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'SYSTEM_CREDENTIAL_REFERENCE_IMMUTABLE';
  END IF;
  IF NEW.owner_tenant_id IS DISTINCT FROM OLD.owner_tenant_id
     OR NEW.workload_actor_id IS DISTINCT FROM OLD.workload_actor_id
     OR NEW.purpose IS DISTINCT FROM OLD.purpose
     OR NEW.secret_id IS DISTINCT FROM OLD.secret_id
     OR NEW.record_class IS DISTINCT FROM OLD.record_class
     OR NEW.created_at IS DISTINCT FROM OLD.created_at
     OR NEW.updated_at<OLD.updated_at THEN
    RAISE EXCEPTION 'SYSTEM_CREDENTIAL_REFERENCE_IMMUTABLE';
  END IF;
  IF OLD.lifecycle_state='CANDIDATE'
     AND NEW.lifecycle_state='ACTIVE'
     AND NEW.generation=OLD.generation
     AND NEW.version=OLD.version+1
     AND EXISTS (
       SELECT 1 FROM system_credential_transition pending_transition
        WHERE pending_transition.owner_tenant_id=OLD.owner_tenant_id
          AND pending_transition.workload_actor_id=OLD.workload_actor_id
          AND pending_transition.purpose=OLD.purpose
          AND pending_transition.secret_id=OLD.secret_id
          AND pending_transition.operation_kind='CREATE'
          AND pending_transition.operation_phase='PREPARED'
          AND pending_transition.target_generation=NEW.generation
     ) THEN
    RETURN NEW;
  END IF;
  IF OLD.lifecycle_state='ACTIVE'
     AND NEW.lifecycle_state='ACTIVE'
     AND NEW.generation=OLD.generation+1
     AND NEW.version=OLD.version+1
     AND EXISTS (
       SELECT 1 FROM system_credential_transition pending_transition
        WHERE pending_transition.owner_tenant_id=OLD.owner_tenant_id
          AND pending_transition.workload_actor_id=OLD.workload_actor_id
          AND pending_transition.purpose=OLD.purpose
          AND pending_transition.secret_id=OLD.secret_id
          AND pending_transition.operation_kind='ROTATE'
          AND pending_transition.operation_phase='PREPARED'
          AND pending_transition.expected_generation=OLD.generation
          AND pending_transition.target_generation=NEW.generation
     ) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'SYSTEM_CREDENTIAL_REFERENCE_TRANSITION_INVALID';
END
$$;


--
-- Name: secret_management_guard_system_credential_transition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_guard_system_credential_transition() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP='INSERT' THEN
    IF NEW.operation_phase<>'PREPARED' OR NEW.version<>1 THEN
      RAISE EXCEPTION 'SYSTEM_CREDENTIAL_TRANSITION_MUST_START_PREPARED';
    END IF;
    RETURN NEW;
  END IF;
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'SYSTEM_CREDENTIAL_TRANSITION_IMMUTABLE';
  END IF;
  IF OLD.operation_phase='PREPARED'
     AND NEW.operation_phase='PREPARED'
     AND NEW.fence>OLD.fence
     AND NEW.version=OLD.version+1
     AND NEW.operation_id IS NOT DISTINCT FROM OLD.operation_id
     AND NEW.owner_tenant_id IS NOT DISTINCT FROM OLD.owner_tenant_id
     AND NEW.target_tenant_id IS NOT DISTINCT FROM OLD.target_tenant_id
     AND NEW.workload_actor_id IS NOT DISTINCT FROM OLD.workload_actor_id
     AND NEW.purpose IS NOT DISTINCT FROM OLD.purpose
     AND NEW.secret_id IS NOT DISTINCT FROM OLD.secret_id
     AND NEW.operation_kind IS NOT DISTINCT FROM OLD.operation_kind
     AND NEW.expected_generation IS NOT DISTINCT FROM OLD.expected_generation
     AND NEW.target_generation IS NOT DISTINCT FROM OLD.target_generation
     AND NEW.idempotency_key_mac IS NOT DISTINCT FROM OLD.idempotency_key_mac
     AND NEW.canonical_request_mac IS NOT DISTINCT FROM OLD.canonical_request_mac
     AND NEW.actor_id IS NOT DISTINCT FROM OLD.actor_id
     AND NEW.correlation_id IS NOT DISTINCT FROM OLD.correlation_id
     AND NEW.created_at IS NOT DISTINCT FROM OLD.created_at
     AND NEW.updated_at>=OLD.updated_at
     AND EXISTS (
       SELECT 1
         FROM system_credential_transition_material material
        WHERE material.operation_id=OLD.operation_id
          AND material.owner_tenant_id=OLD.owner_tenant_id
          AND material.secret_id=OLD.secret_id
          AND material.target_generation=OLD.target_generation
          AND material.fence=OLD.fence
          AND material.lifecycle_state IN ('STAGED','PROVIDER_WRITTEN')
          AND material.encrypted_envelope IS NOT NULL
     ) THEN
    RETURN NEW;
  END IF;
  IF NEW.operation_id IS DISTINCT FROM OLD.operation_id
     OR NEW.owner_tenant_id IS DISTINCT FROM OLD.owner_tenant_id
     OR NEW.target_tenant_id IS DISTINCT FROM OLD.target_tenant_id
     OR NEW.workload_actor_id IS DISTINCT FROM OLD.workload_actor_id
     OR NEW.purpose IS DISTINCT FROM OLD.purpose
     OR NEW.secret_id IS DISTINCT FROM OLD.secret_id
     OR NEW.operation_kind IS DISTINCT FROM OLD.operation_kind
     OR NEW.expected_generation IS DISTINCT FROM OLD.expected_generation
     OR NEW.target_generation IS DISTINCT FROM OLD.target_generation
     OR NEW.idempotency_key_mac IS DISTINCT FROM OLD.idempotency_key_mac
     OR NEW.canonical_request_mac IS DISTINCT FROM OLD.canonical_request_mac
     OR NEW.fence IS DISTINCT FROM OLD.fence
     OR NEW.actor_id IS DISTINCT FROM OLD.actor_id
     OR NEW.correlation_id IS DISTINCT FROM OLD.correlation_id
     OR NEW.created_at IS DISTINCT FROM OLD.created_at
     OR NEW.updated_at<OLD.updated_at
     OR OLD.operation_phase<>'PREPARED'
     OR NEW.operation_phase NOT IN ('COMMITTED','FAILED')
     OR NEW.version<>OLD.version+1 THEN
    RAISE EXCEPTION 'SYSTEM_CREDENTIAL_TRANSITION_IMMUTABLE';
  END IF;
  IF NEW.operation_phase='COMMITTED'
     AND NOT EXISTS (
       SELECT 1
         FROM system_credential_transition_material material
        WHERE material.operation_id=OLD.operation_id
          AND material.owner_tenant_id=OLD.owner_tenant_id
          AND material.secret_id=OLD.secret_id
          AND material.target_generation=OLD.target_generation
          AND material.fence=OLD.fence
          AND material.lifecycle_state='CONSUMED'
     ) THEN
    RAISE EXCEPTION 'SYSTEM_CREDENTIAL_TRANSITION_MATERIAL_NOT_CONSUMED';
  END IF;
  RETURN NEW;
END
$$;


--
-- Name: secret_management_guard_system_credential_transition_material(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_guard_system_credential_transition_material() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'SYSTEM_CREDENTIAL_TRANSITION_MATERIAL_IMMUTABLE';
  END IF;
  IF TG_OP='INSERT' THEN
    IF NEW.lifecycle_state<>'STAGED'
       OR NEW.version<>1
       OR NEW.provider_written_at IS NOT NULL
       OR NEW.consumed_at IS NOT NULL
       OR NEW.encrypted_envelope IS NULL
       OR octet_length(NEW.encrypted_envelope)=0
       OR NOT EXISTS (
         SELECT 1
           FROM system_credential_transition pending_transition
           JOIN secret_record stored_record
             ON stored_record.secret_id=pending_transition.secret_id
            AND stored_record.owner_tenant_id=pending_transition.owner_tenant_id
          JOIN secret_provider_assignment assignment
            ON assignment.assignment_id=NEW.storage_assignment_id
           AND assignment.consumer_tenant_id='__platform__'
          WHERE pending_transition.operation_id=NEW.operation_id
            AND pending_transition.owner_tenant_id=NEW.owner_tenant_id
            AND pending_transition.secret_id=NEW.secret_id
            AND pending_transition.target_generation=NEW.target_generation
            AND pending_transition.fence=NEW.fence
            AND pending_transition.operation_phase='PREPARED'
            AND stored_record.record_class='SYSTEM_CREDENTIAL'
            AND stored_record.storage_consumer_tenant_id='__platform__'
           AND assignment.version=NEW.storage_assignment_version
           AND assignment.assignment_role='PLATFORM_STORAGE'
           AND assignment.lifecycle_state='ACTIVE'
           AND (
             (
               pending_transition.operation_kind='CREATE'
               AND stored_record.lifecycle_state='CANDIDATE'
               AND stored_record.generation=pending_transition.target_generation
               AND stored_record.assignment_id=NEW.storage_assignment_id
             )
             OR
             (
               pending_transition.operation_kind='ROTATE'
               AND stored_record.lifecycle_state='ACTIVE'
               AND stored_record.generation=pending_transition.expected_generation
             )
           )
       ) THEN
      RAISE EXCEPTION 'SYSTEM_CREDENTIAL_TRANSITION_MATERIAL_INVALID';
    END IF;
    RETURN NEW;
  END IF;
  IF OLD.lifecycle_state IN ('STAGED','PROVIDER_WRITTEN')
     AND NEW.lifecycle_state='STAGED'
     AND NEW.fence>OLD.fence
     AND NEW.envelope_version=NEW.fence
     AND NEW.version=OLD.version+1
     AND NEW.provider_written_at IS NULL
     AND NEW.consumed_at IS NULL
     AND NEW.encrypted_envelope IS NOT NULL
     AND octet_length(NEW.encrypted_envelope)>0
     AND NEW.operation_id IS NOT DISTINCT FROM OLD.operation_id
     AND NEW.owner_tenant_id IS NOT DISTINCT FROM OLD.owner_tenant_id
     AND NEW.secret_id IS NOT DISTINCT FROM OLD.secret_id
     AND NEW.target_generation IS NOT DISTINCT FROM OLD.target_generation
     AND NEW.storage_consumer_tenant_id IS NOT DISTINCT FROM OLD.storage_consumer_tenant_id
     AND NEW.created_at IS NOT DISTINCT FROM OLD.created_at
     AND NEW.updated_at>=OLD.updated_at
     AND EXISTS (
       SELECT 1
         FROM system_credential_transition pending_transition
         JOIN secret_record stored_record
           ON stored_record.secret_id=pending_transition.secret_id
          AND stored_record.owner_tenant_id=pending_transition.owner_tenant_id
         JOIN secret_provider_assignment assignment
           ON assignment.assignment_id=NEW.storage_assignment_id
           AND assignment.consumer_tenant_id='__platform__'
        WHERE pending_transition.operation_id=NEW.operation_id
          AND pending_transition.owner_tenant_id=NEW.owner_tenant_id
          AND pending_transition.secret_id=NEW.secret_id
          AND pending_transition.target_generation=NEW.target_generation
          AND pending_transition.fence=NEW.fence
           AND pending_transition.operation_phase='PREPARED'
           AND stored_record.record_class='SYSTEM_CREDENTIAL'
           AND stored_record.storage_consumer_tenant_id='__platform__'
           AND assignment.version=NEW.storage_assignment_version
           AND assignment.assignment_role='PLATFORM_STORAGE'
           AND assignment.lifecycle_state='ACTIVE'
           AND (
             (
               pending_transition.operation_kind='CREATE'
               AND stored_record.lifecycle_state='CANDIDATE'
               AND stored_record.generation=pending_transition.target_generation
               AND stored_record.assignment_id=NEW.storage_assignment_id
             )
             OR
             (
               pending_transition.operation_kind='ROTATE'
               AND stored_record.lifecycle_state='ACTIVE'
               AND stored_record.generation=pending_transition.expected_generation
             )
           )
     ) THEN
    RETURN NEW;
  END IF;
  IF NEW.operation_id IS DISTINCT FROM OLD.operation_id
     OR NEW.owner_tenant_id IS DISTINCT FROM OLD.owner_tenant_id
     OR NEW.secret_id IS DISTINCT FROM OLD.secret_id
     OR NEW.target_generation IS DISTINCT FROM OLD.target_generation
     OR NEW.storage_assignment_id IS DISTINCT FROM OLD.storage_assignment_id
     OR NEW.storage_consumer_tenant_id IS DISTINCT FROM OLD.storage_consumer_tenant_id
     OR NEW.storage_assignment_version IS DISTINCT FROM OLD.storage_assignment_version
     OR NEW.fence IS DISTINCT FROM OLD.fence
     OR NEW.aad_digest IS DISTINCT FROM OLD.aad_digest
     OR NEW.credential_id IS DISTINCT FROM OLD.credential_id
     OR NEW.kek_id IS DISTINCT FROM OLD.kek_id
     OR NEW.kek_version IS DISTINCT FROM OLD.kek_version
     OR NEW.envelope_version IS DISTINCT FROM OLD.envelope_version
     OR NEW.created_at IS DISTINCT FROM OLD.created_at
     OR NEW.updated_at<OLD.updated_at
     OR NEW.version<>OLD.version+1
     OR NOT EXISTS (
       SELECT 1
         FROM system_credential_transition pending_transition
        WHERE pending_transition.operation_id=OLD.operation_id
          AND pending_transition.owner_tenant_id=OLD.owner_tenant_id
          AND pending_transition.secret_id=OLD.secret_id
          AND pending_transition.target_generation=OLD.target_generation
          AND pending_transition.fence=OLD.fence
          AND pending_transition.operation_phase='PREPARED'
     ) THEN
    RAISE EXCEPTION 'SYSTEM_CREDENTIAL_TRANSITION_MATERIAL_IMMUTABLE';
  END IF;
  IF OLD.lifecycle_state='STAGED'
     AND NEW.lifecycle_state='PROVIDER_WRITTEN'
     AND OLD.provider_written_at IS NULL
     AND NEW.provider_written_at IS NOT NULL
     AND NEW.consumed_at IS NULL
     AND NEW.encrypted_envelope IS NOT DISTINCT FROM OLD.encrypted_envelope
     AND NEW.encrypted_envelope IS NOT NULL THEN
    RETURN NEW;
  END IF;
  IF OLD.lifecycle_state='PROVIDER_WRITTEN'
     AND NEW.lifecycle_state='CONSUMED'
     AND NEW.provider_written_at=OLD.provider_written_at
     AND OLD.consumed_at IS NULL
     AND NEW.consumed_at IS NOT NULL
     AND OLD.encrypted_envelope IS NOT NULL
     AND NEW.encrypted_envelope IS NULL THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'SYSTEM_CREDENTIAL_TRANSITION_MATERIAL_STATE_INVALID';
END
$$;


--
-- Name: secret_management_guard_system_credential_use_binding(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_guard_system_credential_use_binding() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE reference_state TEXT;
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'SYSTEM_CREDENTIAL_USE_BINDING_IMMUTABLE';
  END IF;
  SELECT lifecycle_state INTO reference_state
    FROM system_credential_reference
   WHERE owner_tenant_id=NEW.owner_tenant_id
     AND workload_actor_id=NEW.workload_actor_id
     AND purpose=NEW.purpose
     AND secret_id=NEW.secret_id;
  IF reference_state IS DISTINCT FROM 'CANDIDATE' THEN
    RAISE EXCEPTION 'SYSTEM_CREDENTIAL_USE_BINDING_REFERENCE_NOT_CANDIDATE';
  END IF;
  IF TG_OP='INSERT' THEN
    IF NEW.lifecycle_state<>'CANDIDATE' OR NEW.version<>1 THEN
      RAISE EXCEPTION 'SYSTEM_CREDENTIAL_USE_BINDING_MUST_START_CANDIDATE';
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.owner_tenant_id IS DISTINCT FROM OLD.owner_tenant_id
     OR NEW.reader_actor_id IS DISTINCT FROM OLD.reader_actor_id
     OR NEW.secret_id IS DISTINCT FROM OLD.secret_id
     OR NEW.workload_actor_id IS DISTINCT FROM OLD.workload_actor_id
     OR NEW.purpose IS DISTINCT FROM OLD.purpose
     OR NEW.created_at IS DISTINCT FROM OLD.created_at
     OR NEW.updated_at<OLD.updated_at
     OR OLD.lifecycle_state<>'CANDIDATE'
     OR NEW.lifecycle_state<>'ACTIVE'
     OR NEW.version<>OLD.version+1 THEN
    RAISE EXCEPTION 'SYSTEM_CREDENTIAL_USE_BINDING_IMMUTABLE';
  END IF;
  RETURN NEW;
END
$$;


--
-- Name: secret_management_guard_tenant_collection_version(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_guard_tenant_collection_version() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF current_user<>'secret_management_tenant_serving' THEN
    RETURN NEW;
  END IF;
  IF NEW.scope_kind IS DISTINCT FROM OLD.scope_kind
     OR NEW.scope_id IS DISTINCT FROM OLD.scope_id
     OR NEW.collection_kind IS DISTINCT FROM OLD.collection_kind
     OR NEW.collection_kind='INTERNAL_SECRET'
     OR NEW.policy_version IS DISTINCT FROM OLD.policy_version
     OR NEW.version<>OLD.version+1
     OR NEW.updated_at<OLD.updated_at THEN
    RAISE EXCEPTION 'SECRET_COLLECTION_VERSION_TENANT_UPDATE_INVALID';
  END IF;
  RETURN NEW;
END
$$;


--
-- Name: secret_management_maintain_assignment_count(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_maintain_assignment_count() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
BEGIN
    IF TG_OP='INSERT' AND NEW.lifecycle_state='ACTIVE' THEN
        UPDATE public.platform_secret_provider_offering
           SET assignment_count=assignment_count+1
         WHERE offering_id=NEW.offering_id;
        RETURN NEW;
    ELSIF TG_OP='DELETE' AND OLD.lifecycle_state='ACTIVE' THEN
        UPDATE public.platform_secret_provider_offering
           SET assignment_count=assignment_count-1
         WHERE offering_id=OLD.offering_id;
        RETURN OLD;
    ELSIF TG_OP='UPDATE' THEN
        IF OLD.lifecycle_state='ACTIVE'
           AND (NEW.lifecycle_state<>'ACTIVE' OR NEW.offering_id IS DISTINCT FROM OLD.offering_id) THEN
            UPDATE public.platform_secret_provider_offering
               SET assignment_count=assignment_count-1
             WHERE offering_id=OLD.offering_id;
        END IF;
        IF NEW.lifecycle_state='ACTIVE'
           AND (OLD.lifecycle_state<>'ACTIVE' OR NEW.offering_id IS DISTINCT FROM OLD.offering_id) THEN
            UPDATE public.platform_secret_provider_offering
               SET assignment_count=assignment_count+1
             WHERE offering_id=NEW.offering_id;
        END IF;
    END IF;
    RETURN NEW;
END
$$;


--
-- Name: secret_management_record_bootstrap_generation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_record_bootstrap_generation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO platform_bootstrap_credential_generation(credential_id, generation, created_at)
  VALUES (NEW.credential_id, NEW.generation, NEW.updated_at)
  ON CONFLICT (credential_id, generation) DO NOTHING;
  RETURN NEW;
END
$$;


--
-- Name: secret_management_record_secret_generation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_record_secret_generation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO secret_record_generation(
    secret_id, owner_tenant_id, generation, storage_consumer_tenant_id, record_class, created_at
  ) VALUES (
    NEW.secret_id, NEW.owner_tenant_id, NEW.generation,
    NEW.storage_consumer_tenant_id, NEW.record_class, NEW.updated_at
  )
  ON CONFLICT (secret_id, owner_tenant_id, generation) DO NOTHING;
  RETURN NEW;
END
$$;


--
-- Name: secret_management_sync_policy_collection_version(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_sync_policy_collection_version() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE effective_version BIGINT;
DECLARE effective_tenant TEXT;
BEGIN
  IF TG_TABLE_NAME='global_tenant_secret_policy' THEN
    UPDATE secret_collection_version
       SET policy_version=NEW.version, version=version+1, updated_at=NEW.updated_at
     WHERE scope_kind='TENANT' AND collection_kind='TENANT_PROVIDER'
       AND policy_version < NEW.version;
  ELSIF TG_OP <> 'DELETE' THEN
    UPDATE secret_collection_version
       SET policy_version=NEW.version, version=version+1, updated_at=NEW.updated_at
     WHERE scope_kind='TENANT' AND scope_id=NEW.tenant_id
       AND collection_kind='TENANT_PROVIDER'
       AND policy_version < NEW.version;
  ELSE
    effective_tenant := OLD.tenant_id;
    SELECT version INTO effective_version FROM global_tenant_secret_policy WHERE policy_key='global';
    UPDATE secret_collection_version
       SET policy_version=effective_version, version=version+1,
           updated_at=(EXTRACT(EPOCH FROM clock_timestamp())*1000)::BIGINT
     WHERE scope_kind='TENANT' AND scope_id=effective_tenant
       AND collection_kind='TENANT_PROVIDER';
  END IF;
  RETURN COALESCE(NEW, OLD);
END
$$;


--
-- Name: secret_management_validate_current_credential_material(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_validate_current_credential_material() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  d TEXT;
  r BIGINT;
  f TEXT;
  tier TEXT;
  current_generation BIGINT;
  is_configured BOOLEAN;
  bootstrap_current INTEGER;
  platform_current INTEGER;
  bootstrap_all INTEGER;
  platform_all INTEGER;
BEGIN
  d := COALESCE(NEW.definition_id, OLD.definition_id);
  r := COALESCE(NEW.revision, OLD.revision);
  f := COALESCE(NEW.credential_field, OLD.credential_field);
  SELECT storage_tier, generation, configured
    INTO tier, current_generation, is_configured
    FROM secret_provider_credential_binding
   WHERE definition_id=d AND revision=r AND credential_field=f;
  IF tier IS NULL THEN RETURN COALESCE(NEW, OLD); END IF;
  SELECT COUNT(*) INTO bootstrap_current
    FROM secret_provider_bootstrap_credential_material
   WHERE definition_id=d AND revision=r AND credential_field=f
     AND material_generation=current_generation;
  SELECT COUNT(*) INTO platform_current
    FROM secret_provider_platform_credential_material
   WHERE definition_id=d AND revision=r AND credential_field=f
     AND material_generation=current_generation;
  SELECT COUNT(*) INTO bootstrap_all
    FROM secret_provider_bootstrap_credential_material
   WHERE definition_id=d AND revision=r AND credential_field=f;
  SELECT COUNT(*) INTO platform_all
    FROM secret_provider_platform_credential_material
   WHERE definition_id=d AND revision=r AND credential_field=f;
  IF is_configured AND (
       (tier='BOOTSTRAP' AND (bootstrap_current<>1 OR platform_all<>0))
       OR (tier='PLATFORM' AND (platform_current<>1 OR bootstrap_all<>0))
     ) THEN
    RAISE EXCEPTION 'SECRET_PROVIDER_CREDENTIAL_MATERIAL_EXACT_MATCH_REQUIRED';
  END IF;
  IF NOT is_configured AND (
       (tier='BOOTSTRAP' AND (bootstrap_current<>0 OR platform_all<>0))
       OR (tier='PLATFORM' AND (platform_current<>0 OR bootstrap_all<>0))
     ) THEN
    RAISE EXCEPTION 'SECRET_PROVIDER_UNCONFIGURED_MATERIAL_NOT_PERMITTED';
  END IF;
  RETURN COALESCE(NEW, OLD);
END
$$;


--
-- Name: secret_management_validate_current_tenant_capability(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_validate_current_tenant_capability() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_tenant_id TEXT;
  v_binding_id TEXT;
  current_generation BIGINT;
  binding_state TEXT;
  provider_type_value TEXT;
  active_generation_count INTEGER;
  material_count INTEGER;
  material_fields TEXT;
  proof_count INTEGER;
BEGIN
  v_tenant_id := COALESCE(NEW.tenant_id, OLD.tenant_id);
  v_binding_id := COALESCE(NEW.binding_id, OLD.binding_id);
  SELECT capability_generation, lifecycle_state
    INTO current_generation, binding_state
    FROM tenant_provider_binding
   WHERE tenant_id=v_tenant_id AND binding_id=v_binding_id;
  IF binding_state IS NULL OR binding_state NOT IN ('READY','ACTIVE') THEN
    RETURN COALESCE(NEW, OLD);
  END IF;
  SELECT COUNT(*) INTO active_generation_count
    FROM tenant_provider_capability_generation
   WHERE tenant_id=v_tenant_id AND binding_id=v_binding_id
     AND capability_generation=current_generation
     AND lifecycle_state IN ('READY','ACTIVE');
  SELECT g.provider_type, COUNT(m.credential_field), string_agg(m.credential_field, ',' ORDER BY m.credential_field)
    INTO provider_type_value, material_count, material_fields
    FROM tenant_provider_capability_generation g
    LEFT JOIN tenant_provider_capability_material m
      ON m.tenant_id=g.tenant_id
     AND m.binding_id=g.binding_id
     AND m.capability_generation=g.capability_generation
   WHERE g.tenant_id=v_tenant_id
     AND g.binding_id=v_binding_id
     AND g.capability_generation=current_generation
   GROUP BY g.provider_type;
  SELECT
    (SELECT COUNT(*) FROM tenant_provider_isolation_proof_kms
      WHERE tenant_id=v_tenant_id AND binding_id=v_binding_id
        AND capability_generation=current_generation)
    +(SELECT COUNT(*) FROM tenant_provider_isolation_proof_vault
      WHERE tenant_id=v_tenant_id AND binding_id=v_binding_id
        AND capability_generation=current_generation)
    +(SELECT COUNT(*) FROM tenant_provider_isolation_proof_azure
      WHERE tenant_id=v_tenant_id AND binding_id=v_binding_id
        AND capability_generation=current_generation)
    +(SELECT COUNT(*) FROM tenant_provider_isolation_proof_aws
      WHERE tenant_id=v_tenant_id AND binding_id=v_binding_id
        AND capability_generation=current_generation)
    INTO proof_count;
  IF active_generation_count<>1 OR proof_count<>1
     OR (provider_type_value='VAULT' AND material_fields IS DISTINCT FROM 'roleId,secretId')
     OR (provider_type_value='AWS_SECRETS_MANAGER' AND material_fields IS DISTINCT FROM 'externalId')
     OR (provider_type_value='KMS' AND material_count<>0)
     OR provider_type_value='AZURE_KEY_VAULT' THEN
    RAISE EXCEPTION 'SECRET_PROVIDER_BINDING_CAPABILITY_EXACT_MATCH_REQUIRED';
  END IF;
  RETURN COALESCE(NEW, OLD);
END
$$;


--
-- Name: secret_management_validate_ready_revision(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secret_management_validate_ready_revision() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    config_count INTEGER;
    matching_count INTEGER;
    read_count INTEGER;
    write_count INTEGER;
    total_capability_count INTEGER;
    manifest_count INTEGER;
    committed_preflight_count INTEGER;
    definition_owner_scope TEXT;
BEGIN
    IF NEW.lifecycle_state NOT IN ('READY', 'ACTIVE')
       OR OLD.lifecycle_state IN ('READY', 'ACTIVE') THEN
        RETURN NEW;
    END IF;
    SELECT
      (SELECT COUNT(*) FROM secret_provider_revision_kms WHERE definition_id=NEW.definition_id AND revision=NEW.revision) +
      (SELECT COUNT(*) FROM secret_provider_revision_vault WHERE definition_id=NEW.definition_id AND revision=NEW.revision) +
      (SELECT COUNT(*) FROM secret_provider_revision_azure WHERE definition_id=NEW.definition_id AND revision=NEW.revision) +
      (SELECT COUNT(*) FROM secret_provider_revision_aws WHERE definition_id=NEW.definition_id AND revision=NEW.revision) +
      (SELECT COUNT(*) FROM secret_provider_revision_kubernetes_mount WHERE definition_id=NEW.definition_id AND revision=NEW.revision) +
      (SELECT COUNT(*) FROM secret_provider_revision_environment WHERE definition_id=NEW.definition_id AND revision=NEW.revision)
    INTO config_count;
    SELECT CASE NEW.provider_type
      WHEN 'KMS' THEN (SELECT COUNT(*) FROM secret_provider_revision_kms WHERE definition_id=NEW.definition_id AND revision=NEW.revision)
      WHEN 'VAULT' THEN (SELECT COUNT(*) FROM secret_provider_revision_vault WHERE definition_id=NEW.definition_id AND revision=NEW.revision)
      WHEN 'AZURE_KEY_VAULT' THEN (SELECT COUNT(*) FROM secret_provider_revision_azure WHERE definition_id=NEW.definition_id AND revision=NEW.revision)
      WHEN 'AWS_SECRETS_MANAGER' THEN (SELECT COUNT(*) FROM secret_provider_revision_aws WHERE definition_id=NEW.definition_id AND revision=NEW.revision)
      WHEN 'KUBERNETES_MOUNT' THEN (SELECT COUNT(*) FROM secret_provider_revision_kubernetes_mount WHERE definition_id=NEW.definition_id AND revision=NEW.revision)
      WHEN 'ENVIRONMENT' THEN (SELECT COUNT(*) FROM secret_provider_revision_environment WHERE definition_id=NEW.definition_id AND revision=NEW.revision)
      ELSE 0 END
    INTO matching_count;
    IF config_count <> 1 OR matching_count <> 1 THEN
        RAISE EXCEPTION 'SECRET_PROVIDER_EXACT_TYPED_CONFIGURATION_REQUIRED';
    END IF;
    IF NEW.provider_type IN ('KUBERNETES_MOUNT','ENVIRONMENT') THEN
        SELECT COUNT(*) INTO read_count
          FROM secret_provider_revision_capability
         WHERE definition_id=NEW.definition_id AND revision=NEW.revision
           AND capability='READ';
        SELECT COUNT(*) INTO write_count
          FROM secret_provider_revision_capability
         WHERE definition_id=NEW.definition_id AND revision=NEW.revision
           AND capability IN ('WRITE','DELETE','CREDENTIAL_ROTATION');
        SELECT COUNT(*) INTO total_capability_count
          FROM secret_provider_revision_capability
         WHERE definition_id=NEW.definition_id AND revision=NEW.revision;
        IF read_count <> 1 OR write_count <> 0 OR total_capability_count <> 1
           OR NEW.isolation_mode <> 'READ_ONLY_DEPLOYMENT' THEN
            RAISE EXCEPTION 'SECRET_PROVIDER_DEPLOYMENT_SOURCE_MUST_BE_READ_ONLY';
        END IF;
    END IF;
    IF NEW.provider_type = 'ENVIRONMENT' THEN
        SELECT COUNT(*) INTO manifest_count
          FROM secret_provider_environment_manifest_item
         WHERE definition_id=NEW.definition_id AND revision=NEW.revision;
        IF manifest_count = 0 THEN
            RAISE EXCEPTION 'SECRET_PROVIDER_ENVIRONMENT_MANIFEST_REQUIRED';
        END IF;
    ELSIF NEW.provider_type = 'KUBERNETES_MOUNT' THEN
        SELECT COUNT(*) INTO manifest_count
          FROM secret_provider_kubernetes_mount_manifest_item
         WHERE definition_id=NEW.definition_id AND revision=NEW.revision;
        IF manifest_count = 0 THEN
            RAISE EXCEPTION 'SECRET_PROVIDER_KUBERNETES_MOUNT_MANIFEST_REQUIRED';
        END IF;
    END IF;
    SELECT owner_scope
      INTO definition_owner_scope
      FROM secret_provider_definition
     WHERE definition_id=NEW.definition_id;
    SELECT COUNT(*) INTO committed_preflight_count
      FROM secret_preflight_journal
     WHERE target_definition_id=NEW.definition_id
       AND target_revision=NEW.revision
       AND target_owner_scope=definition_owner_scope
       AND consumer_tenant_id=definition_owner_scope
       AND target_tenant_binding_id IS NULL
       AND operation_state='COMMITTED'
       AND expires_at > (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::BIGINT
       AND version > 0;
    IF committed_preflight_count=0 THEN
        RAISE EXCEPTION 'SECRET_PROVIDER_READY_PREFLIGHT_REQUIRED';
    END IF;
    RETURN NEW;
END
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: _schema_version; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public._schema_version (
    schema_name character varying(190) NOT NULL,
    version integer NOT NULL
);


--
-- Name: activated_license; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activated_license (
    id integer NOT NULL,
    token text,
    installation_owner_party_id text,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT activated_license_id_check CHECK ((id = 1))
);


--
-- Name: app_party; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_party (
    party_id text NOT NULL,
    platform_type text,
    distribution_model text,
    assignment_model text,
    bundle_identifier text,
    package_name text,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: application_login_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.application_login_config (
    application_id text NOT NULL,
    tenant_id text NOT NULL,
    allowed_methods text NOT NULL,
    login_identifier_types text NOT NULL,
    allowed_idp_ids text NOT NULL,
    self_registration integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: audit_event; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_event (
    id text NOT NULL,
    command_id text NOT NULL,
    module text NOT NULL,
    service text NOT NULL,
    command text NOT NULL,
    actor_id text,
    subject_id text,
    resource_id text,
    result text NOT NULL,
    tenant_id text,
    trace_id text,
    span_id text,
    correlation_id text,
    duration_ms bigint,
    error_code text,
    error_message text,
    transport_type text,
    transport_scope text,
    metadata text DEFAULT '{}'::text,
    prev_hash text,
    event_hash text,
    created_at timestamp with time zone NOT NULL
);


--
-- Name: auth_rate_limit_bucket; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_rate_limit_bucket (
    tenant_id text NOT NULL,
    operation text NOT NULL,
    remote_ip text NOT NULL,
    count integer NOT NULL,
    window_start timestamp with time zone NOT NULL,
    last_seen timestamp with time zone NOT NULL
);


--
-- Name: auth_session; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_session (
    session_id text NOT NULL,
    tenant_id text NOT NULL,
    identity_id uuid NOT NULL,
    method text NOT NULL,
    authenticated_at timestamp with time zone NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    acr text,
    amr text DEFAULT '[]'::text NOT NULL,
    return_url text,
    remote_ip text,
    rps_participated text DEFAULT '[]'::text NOT NULL,
    upstream_issuer text,
    upstream_sid text,
    upstream_sub text,
    application_id uuid
);


--
-- Name: authorization_server_federation_binding; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.authorization_server_federation_binding (
    id text NOT NULL,
    tenant_id text NOT NULL,
    hosted_authorization_server_id text NOT NULL,
    external_authorization_server_id text NOT NULL,
    display_order integer DEFAULT 0 NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    scopes jsonb DEFAULT '[]'::jsonb NOT NULL,
    claims_mapping jsonb DEFAULT '{}'::jsonb NOT NULL,
    upstream_client_authentication_method text NOT NULL,
    upstream_client_id text,
    secret_resource_handle text,
    secret_record_version bigint,
    secret_purpose text,
    kms_resource_handle text,
    kms_key_alias text,
    kms_purpose text,
    status text DEFAULT 'UNVALIDATED'::text NOT NULL,
    last_validated_at timestamp with time zone,
    revision bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text,
    CONSTRAINT ck_asfb_disabled_status CHECK (((status <> 'DISABLED'::text) OR (NOT enabled))),
    CONSTRAINT ck_asfb_distinct_endpoints CHECK ((hosted_authorization_server_id <> external_authorization_server_id)),
    CONSTRAINT ck_asfb_enabled_validation CHECK (((NOT enabled) OR ((status = 'VALID'::text) AND (last_validated_at IS NOT NULL)))),
    CONSTRAINT ck_asfb_method CHECK ((upstream_client_authentication_method = ANY (ARRAY['none'::text, 'client_secret_basic'::text, 'client_secret_post'::text, 'private_key_jwt'::text]))),
    CONSTRAINT ck_asfb_order CHECK ((display_order >= 0)),
    CONSTRAINT ck_asfb_revision CHECK ((revision >= 0)),
    CONSTRAINT ck_asfb_secret_record CHECK (((secret_resource_handle IS NULL) = (secret_record_version IS NULL))),
    CONSTRAINT ck_asfb_status CHECK ((status = ANY (ARRAY['UNVALIDATED'::text, 'VALID'::text, 'INVALID'::text, 'DISABLED'::text]))),
    CONSTRAINT ck_asfb_typed_credential_reference CHECK ((((upstream_client_authentication_method = 'none'::text) AND (secret_resource_handle IS NULL) AND (secret_purpose IS NULL) AND (kms_resource_handle IS NULL) AND (kms_key_alias IS NULL) AND (kms_purpose IS NULL)) OR ((upstream_client_authentication_method = ANY (ARRAY['client_secret_basic'::text, 'client_secret_post'::text])) AND (secret_resource_handle IS NOT NULL) AND (secret_purpose = 'OAUTH_CLIENT_SECRET'::text) AND (kms_resource_handle IS NULL) AND (kms_key_alias IS NULL) AND (kms_purpose IS NULL)) OR ((upstream_client_authentication_method = 'private_key_jwt'::text) AND (secret_resource_handle IS NULL) AND (secret_purpose IS NULL) AND (kms_resource_handle IS NOT NULL) AND (kms_key_alias IS NOT NULL) AND (kms_purpose = 'OAUTH_CLIENT_ASSERTION_SIGNING'::text))))
);


--
-- Name: authorization_server_hosted_configuration; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.authorization_server_hosted_configuration (
    tenant_id text NOT NULL,
    authorization_server_id text NOT NULL,
    config_key_prefix text NOT NULL,
    configuration jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: authorization_server_hosted_signing; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.authorization_server_hosted_signing (
    tenant_id text NOT NULL,
    authorization_server_id text NOT NULL,
    signing jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: authorization_server_migration_completion; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.authorization_server_migration_completion (
    tenant_id text NOT NULL,
    migration_version integer NOT NULL,
    completed_at timestamp with time zone NOT NULL,
    completed_by_id text
);


--
-- Name: authorization_server_migration_ledger; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.authorization_server_migration_ledger (
    id text NOT NULL,
    tenant_id text NOT NULL,
    migration_version integer NOT NULL,
    source_type text NOT NULL,
    source_key text NOT NULL,
    source_digest_sha256 text NOT NULL,
    observed_source_digest_sha256 text,
    target_authorization_server_id text,
    status text NOT NULL,
    revision integer DEFAULT 0 NOT NULL,
    attempt_count integer DEFAULT 0 NOT NULL,
    last_attempt_at timestamp with time zone NOT NULL,
    applied_at timestamp with time zone,
    failure_code text,
    details jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    CONSTRAINT ck_asml_attempt_count CHECK ((attempt_count >= 0)),
    CONSTRAINT ck_asml_observed_source_digest CHECK (((observed_source_digest_sha256 IS NULL) OR (observed_source_digest_sha256 ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT ck_asml_revision CHECK ((revision >= 0)),
    CONSTRAINT ck_asml_source_digest CHECK ((source_digest_sha256 ~ '^[0-9a-f]{64}$'::text))
);


--
-- Name: authorization_server_migration_source_change; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.authorization_server_migration_source_change (
    id text NOT NULL,
    ledger_id text NOT NULL,
    tenant_id text NOT NULL,
    previous_digest_sha256 text NOT NULL,
    accepted_digest_sha256 text NOT NULL,
    reason text NOT NULL,
    accepted_at timestamp with time zone NOT NULL,
    accepted_by_id text NOT NULL,
    CONSTRAINT ck_asmlsc_accepted_digest CHECK ((accepted_digest_sha256 ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT ck_asmlsc_actor CHECK ((btrim(accepted_by_id) <> ''::text)),
    CONSTRAINT ck_asmlsc_previous_digest CHECK ((previous_digest_sha256 ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT ck_asmlsc_reason CHECK ((btrim(reason) <> ''::text))
);


--
-- Name: authorization_server_resource; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.authorization_server_resource (
    id text NOT NULL,
    tenant_id text NOT NULL,
    authorization_server_capability_id text NOT NULL,
    slug text NOT NULL,
    display_name text NOT NULL,
    issuer text NOT NULL,
    lifecycle text NOT NULL,
    deployment text NOT NULL,
    authentication_mode text,
    purposes jsonb DEFAULT '[]'::jsonb NOT NULL,
    usages jsonb DEFAULT '[]'::jsonb NOT NULL,
    allowed_grant_types jsonb DEFAULT '[]'::jsonb NOT NULL,
    capabilities jsonb DEFAULT '[]'::jsonb NOT NULL,
    expected_capabilities jsonb DEFAULT '[]'::jsonb NOT NULL,
    system boolean DEFAULT false NOT NULL,
    default_purposes jsonb DEFAULT '[]'::jsonb NOT NULL,
    discovery_capabilities jsonb,
    discovery_grant_types jsonb,
    discovery_token_endpoint_auth_methods_supported jsonb,
    discovery_issuer text,
    discovery_authorization_endpoint text,
    discovery_token_endpoint text,
    discovery_registration_endpoint text,
    discovery_userinfo_endpoint text,
    discovery_pushed_authorization_request_endpoint text,
    discovery_jwks_uri text,
    discovery_scopes_supported jsonb,
    discovery_id_token_signing_algorithms jsonb,
    discovery_source_urls jsonb,
    discovery_digest text,
    discovery_validated_at timestamp with time zone,
    discovery_valid_until timestamp with time zone,
    discovery_freshness text,
    revision bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text,
    CONSTRAINT ck_asr_authentication_mode CHECK (((authentication_mode IS NULL) OR (authentication_mode = ANY (ARRAY['LOCAL_ONLY'::text, 'FEDERATED_ONLY'::text, 'HYBRID'::text])))),
    CONSTRAINT ck_asr_deployment CHECK ((deployment = ANY (ARRAY['HOSTED'::text, 'EXTERNAL'::text]))),
    CONSTRAINT ck_asr_discovery_digest CHECK (((discovery_digest IS NULL) OR (discovery_digest ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT ck_asr_discovery_freshness CHECK (((discovery_freshness IS NULL) OR (discovery_freshness = ANY (ARRAY['CURRENT'::text, 'STALE'::text, 'INVALID'::text, 'UNAVAILABLE'::text])))),
    CONSTRAINT ck_asr_lifecycle CHECK ((lifecycle = ANY (ARRAY['DRAFT'::text, 'ACTIVE'::text, 'SUSPENDED'::text, 'DECOMMISSIONED'::text]))),
    CONSTRAINT ck_asr_revision CHECK ((revision >= 0))
);


--
-- Name: authorization_server_secret_purge_outbox; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.authorization_server_secret_purge_outbox (
    id text NOT NULL,
    tenant_id text NOT NULL,
    resource_handle text NOT NULL,
    record_version bigint NOT NULL,
    reason text NOT NULL,
    requested_at text NOT NULL
);


--
-- Name: back_channel_logout_retry; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.back_channel_logout_retry (
    entry_id text NOT NULL,
    tenant_id text NOT NULL,
    identity_id uuid NOT NULL,
    session_id text,
    client_id text NOT NULL,
    backchannel_logout_uri text NOT NULL,
    attempt_count integer NOT NULL,
    max_attempts integer NOT NULL,
    created_at timestamp with time zone NOT NULL,
    next_attempt_at timestamp with time zone NOT NULL,
    last_error text
);


--
-- Name: booking; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.booking (
    id text NOT NULL,
    tenant_id text NOT NULL,
    user_id text,
    booker_party_id text,
    resource_id text NOT NULL,
    booking_type text NOT NULL,
    title text,
    description text,
    start_time timestamp with time zone NOT NULL,
    end_time timestamp with time zone NOT NULL,
    status text NOT NULL,
    verification_status text NOT NULL,
    headcount bigint,
    created_by_id text,
    updated_by_id text,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: booking_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.booking_metadata (
    id text NOT NULL,
    tenant_id text NOT NULL,
    booking_id text NOT NULL,
    key text NOT NULL,
    value_type text NOT NULL,
    text_value text,
    number_value real,
    boolean_value boolean,
    date_value timestamp with time zone,
    json_value text,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: booking_verification; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.booking_verification (
    id text NOT NULL,
    tenant_id text NOT NULL,
    booking_id text NOT NULL,
    requirement_id text NOT NULL,
    oid4vc_state_id text,
    verification_status text NOT NULL,
    credential_hash text,
    verified_at timestamp with time zone,
    expires_at timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: business_wallet_membership; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.business_wallet_membership (
    id text NOT NULL,
    tenant_id text NOT NULL,
    wallet_party_id text NOT NULL,
    identity_id text NOT NULL,
    roles text NOT NULL,
    activated_at timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    revoked_at timestamp with time zone,
    revoked_by_id text
);


--
-- Name: command_execution_idempotency; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.command_execution_idempotency (
    tenant_id text NOT NULL,
    command_id text NOT NULL,
    idempotency_key text NOT NULL,
    execution_id text NOT NULL,
    operation_id text,
    owner_generation bigint DEFAULT 0 NOT NULL,
    request_fingerprint text,
    command_fingerprint text,
    operation_context bytea,
    operation_context_content_type text,
    result_state text,
    result_bytes bytea,
    result_content_type text,
    inserted_at timestamp with time zone NOT NULL,
    expires_at timestamp with time zone NOT NULL
);


--
-- Name: config_setting; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.config_setting (
    id text NOT NULL,
    application_id text DEFAULT 'default'::text NOT NULL,
    tenant_id text NOT NULL,
    scope text NOT NULL,
    scope_identifier text,
    property_key text NOT NULL,
    property_value text NOT NULL,
    value_type text NOT NULL,
    profile text NOT NULL,
    is_final integer NOT NULL,
    is_interpolation_protected integer NOT NULL,
    defined_at_scope text,
    metadata text,
    created_at timestamp with time zone NOT NULL,
    created_by text,
    updated_at timestamp with time zone NOT NULL,
    updated_by text,
    deleted_at timestamp with time zone,
    deleted_by text
);


--
-- Name: connector_capability_detail; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.connector_capability_detail (
    capability_id text NOT NULL,
    detail_json text NOT NULL
);


--
-- Name: credential_actor; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.credential_actor (
    party_id text NOT NULL
);


--
-- Name: credential_actor_credential_definitions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.credential_actor_credential_definitions (
    party_id text NOT NULL,
    credential_definition_id text NOT NULL
);


--
-- Name: credential_definition; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.credential_definition (
    id text NOT NULL,
    display_name text NOT NULL,
    description text,
    credential_template_id text NOT NULL,
    created_by_id text,
    created_at timestamp with time zone NOT NULL,
    updated_by_id text,
    updated_at timestamp with time zone NOT NULL,
    deleted_by_id text,
    deleted_at timestamp with time zone
);


--
-- Name: credential_template; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.credential_template (
    party_id text NOT NULL,
    previous_id text,
    version text NOT NULL,
    identifier text NOT NULL,
    format text NOT NULL,
    scope text,
    metadata_structure_version text,
    metadata jsonb,
    approved_by_id text,
    approved_at timestamp with time zone
);


--
-- Name: credential_template_claim; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.credential_template_claim (
    id text NOT NULL,
    path text NOT NULL,
    is_mandatory boolean DEFAULT false NOT NULL,
    default_value text,
    attribute_type text NOT NULL,
    credential_template_id text NOT NULL,
    disclosable text
);


--
-- Name: credential_template_claim_display; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.credential_template_claim_display (
    id text NOT NULL,
    credential_template_claim_id text NOT NULL,
    name text NOT NULL,
    description text,
    locale text
);


--
-- Name: credential_templates_schemas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.credential_templates_schemas (
    party_id text NOT NULL,
    schema_id text NOT NULL
);


--
-- Name: design_element_binding; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.design_element_binding (
    tenant_id text NOT NULL,
    product_type text NOT NULL,
    feature_id text NOT NULL,
    element_id text NOT NULL,
    application_id text,
    variant text,
    value_json text NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: did_also_known_as; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.did_also_known_as (
    id text NOT NULL,
    did_record_id text NOT NULL,
    aka_uri text NOT NULL,
    ordinal integer NOT NULL,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text
);


--
-- Name: did_controller; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.did_controller (
    id text NOT NULL,
    did_record_id text NOT NULL,
    controller_did text NOT NULL,
    ordinal integer NOT NULL,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text
);


--
-- Name: did_document_context; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.did_document_context (
    id text NOT NULL,
    did_record_id text NOT NULL,
    context_uri text NOT NULL,
    ordinal integer NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: did_equivalent_id; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.did_equivalent_id (
    id text NOT NULL,
    did_record_id text NOT NULL,
    equivalent_did text NOT NULL,
    ordinal integer NOT NULL,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text
);


--
-- Name: did_key_mapping; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.did_key_mapping (
    id text NOT NULL,
    did_record_id text NOT NULL,
    verification_method_id text NOT NULL,
    verification_method_did_url text,
    kms_provider_id text NOT NULL,
    kms_key_alias text NOT NULL,
    kms_kid text,
    key_reference_id text,
    purposes_json text NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: did_record; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.did_record (
    id text NOT NULL,
    tenant_id text NOT NULL,
    did text NOT NULL,
    method text NOT NULL,
    alias text,
    role text NOT NULL,
    canonical_id text,
    web_location text,
    deactivated integer DEFAULT 0 NOT NULL,
    extension_properties_json text,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: did_service; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.did_service (
    id text NOT NULL,
    did_record_id text NOT NULL,
    service_id text NOT NULL,
    type_json text NOT NULL,
    service_endpoint_json text NOT NULL,
    extension_properties_json text,
    ordinal integer NOT NULL,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text
);


--
-- Name: did_verification_method; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.did_verification_method (
    id text NOT NULL,
    did_record_id text NOT NULL,
    vm_id text NOT NULL,
    vm_id_authored text,
    type text NOT NULL,
    controller text NOT NULL,
    kms_provider_id text,
    kms_key_alias text,
    kms_kid text,
    key_reference_id text,
    public_key_jwk_json text,
    public_key_multibase text,
    inline_in_json text,
    expires_at timestamp with time zone,
    revoked_at timestamp with time zone,
    blockchain_account_id text,
    extension_properties_json text,
    ordinal integer NOT NULL,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text
);


--
-- Name: did_verification_relationship; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.did_verification_relationship (
    id text NOT NULL,
    did_record_id text NOT NULL,
    purpose text NOT NULL,
    entry_embedded_vm_id text,
    entry_ref_did_url text,
    ordinal integer NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT did_verification_relationship_check CHECK (((entry_embedded_vm_id IS NOT NULL) OR (entry_ref_did_url IS NOT NULL)))
);


--
-- Name: electronic_address; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.electronic_address (
    id text NOT NULL,
    party_id text NOT NULL,
    identifier_id text,
    address_type text NOT NULL,
    address text NOT NULL,
    label text,
    is_primary integer NOT NULL,
    is_verified integer,
    verified_at timestamp with time zone,
    valid_from timestamp with time zone NOT NULL,
    valid_until timestamp with time zone
);


--
-- Name: event; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event (
    id text NOT NULL,
    tenant_id text NOT NULL,
    type text NOT NULL,
    version text DEFAULT '0.1.0'::text NOT NULL,
    subsystem text NOT NULL,
    category text NOT NULL,
    origin text NOT NULL,
    "timestamp" timestamp with time zone NOT NULL,
    session_id text,
    principal_id text,
    correlation_id text,
    trace_id text,
    span_id text,
    parent_span_id text,
    model_id text,
    stream_id text,
    stream_sequence bigint,
    expected_prior_version bigint,
    command_id text,
    idempotency_key text,
    command_digest_algorithm text,
    command_digest_value text,
    causation_id text,
    actor_type text,
    authority_ref text,
    effective_from timestamp with time zone,
    effective_until timestamp with time zone,
    provenance_json text,
    payload_json text NOT NULL,
    signature_json text,
    encryption_json text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: event_command_receipt; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_command_receipt (
    tenant_id text NOT NULL,
    model_id text NOT NULL,
    stream_id text NOT NULL,
    idempotency_key text NOT NULL,
    command_digest_algorithm text NOT NULL,
    command_digest_value text NOT NULL,
    first_sequence bigint NOT NULL,
    last_sequence bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: event_delivery_receipt; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_delivery_receipt (
    tenant_id text NOT NULL,
    model_id text,
    transmission_id text NOT NULL,
    consumer_id text NOT NULL,
    consumer_idempotency_key text NOT NULL,
    delivered_at timestamp with time zone NOT NULL
);


--
-- Name: event_stream_state; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_stream_state (
    tenant_id text NOT NULL,
    model_id text NOT NULL,
    stream_id text NOT NULL,
    current_version bigint DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: event_transmission; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_transmission (
    id text NOT NULL,
    tenant_id text NOT NULL,
    event_id text NOT NULL,
    model_id text,
    receiver_id text NOT NULL,
    status text DEFAULT 'PENDING'::text NOT NULL,
    error_message text,
    retry_count integer DEFAULT 0 NOT NULL,
    claim_owner text,
    lease_expires_at timestamp with time zone,
    attempt_count integer DEFAULT 0 NOT NULL,
    next_attempt_at timestamp with time zone DEFAULT now() NOT NULL,
    last_error_class text,
    safe_last_error text,
    delivered_at timestamp with time zone,
    dead_lettered_at timestamp with time zone,
    consumer_idempotency_key text,
    transmitted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: global_tenant_secret_policy; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.global_tenant_secret_policy (
    policy_key text NOT NULL,
    allow_tenant_managed_providers boolean NOT NULL,
    allow_platform_offerings boolean NOT NULL,
    require_backend_isolation boolean NOT NULL,
    retention_days integer NOT NULL,
    version bigint NOT NULL,
    updated_at bigint NOT NULL,
    CONSTRAINT global_tenant_secret_policy_policy_key_check CHECK ((policy_key = 'global'::text)),
    CONSTRAINT global_tenant_secret_policy_retention_days_check CHECK (((retention_days >= 0) AND (retention_days <= 3650))),
    CONSTRAINT global_tenant_secret_policy_version_check CHECK ((version > 0))
);


--
-- Name: global_tenant_secret_policy_provider_type; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.global_tenant_secret_policy_provider_type (
    policy_key text NOT NULL,
    provider_type text NOT NULL,
    CONSTRAINT global_tenant_secret_policy_provider_type_provider_type_check CHECK ((provider_type = ANY (ARRAY['KMS'::text, 'VAULT'::text, 'AZURE_KEY_VAULT'::text, 'AWS_SECRETS_MANAGER'::text])))
);


--
-- Name: group_; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.group_ (
    party_id text NOT NULL,
    tenant_id text NOT NULL,
    name text NOT NULL,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: group_membership; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.group_membership (
    id text NOT NULL,
    tenant_id text NOT NULL,
    group_id text NOT NULL,
    member_party_id text NOT NULL,
    role text NOT NULL,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: group_party; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.group_party (
    party_id text NOT NULL,
    tenant_id text NOT NULL,
    name text NOT NULL,
    description text,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: group_role; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.group_role (
    group_party_id text NOT NULL,
    role_id text NOT NULL,
    tenant_id text NOT NULL,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: identifier_electronic; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.identifier_electronic (
    identifier_id text NOT NULL,
    electronic_type text NOT NULL,
    label text
);


--
-- Name: identifier_registration; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.identifier_registration (
    identifier_id text NOT NULL,
    registration_type text NOT NULL,
    issuing_authority text,
    jurisdiction_country text
);


--
-- Name: identifier_x509; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.identifier_x509 (
    identifier_id text NOT NULL,
    issuer_dn text,
    subject_dn text,
    serial_number text,
    certificate_pem text,
    not_before timestamp with time zone,
    not_after timestamp with time zone
);


--
-- Name: identity; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.identity (
    party_id text NOT NULL,
    tenant_id text NOT NULL,
    identity_role text NOT NULL,
    is_default integer DEFAULT 0 NOT NULL,
    specialization_subtype text,
    privacy_mode text DEFAULT 'PARTY_PROFILED'::text NOT NULL,
    salt_ref text,
    salt_ciphertext text,
    salt_key_ref text,
    salt_key_version text,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: identity_application_binding; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.identity_application_binding (
    id text NOT NULL,
    tenant_id text NOT NULL,
    identity_id text NOT NULL,
    application_id text NOT NULL,
    capabilities text NOT NULL,
    allowed_methods text NOT NULL,
    roles text DEFAULT '[]'::text NOT NULL,
    revision bigint DEFAULT 0 NOT NULL,
    specialization_subtype text,
    status text NOT NULL,
    valid_from timestamp with time zone NOT NULL,
    valid_until timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: identity_application_session_revocation_outbox; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.identity_application_session_revocation_outbox (
    id text NOT NULL,
    tenant_id text NOT NULL,
    binding_id text NOT NULL,
    identity_id text NOT NULL,
    application_id text NOT NULL,
    binding_revision bigint NOT NULL,
    reason text NOT NULL,
    requested_at text NOT NULL,
    requested_by_id text
);


--
-- Name: identity_identifier; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.identity_identifier (
    id text NOT NULL,
    identity_id text NOT NULL,
    tenant_id text NOT NULL,
    identifier_type text NOT NULL,
    lookup_value text NOT NULL,
    protection_mode text,
    value_plaintext text,
    value_ciphertext text,
    enc_key_ref text,
    enc_key_version text,
    value_hmac text,
    hmac_key_ref text,
    hmac_key_version text,
    source_kind text,
    source_party_id text,
    source_record_id text,
    source_field text,
    projection_version text,
    is_primary integer DEFAULT 0 NOT NULL,
    is_verified integer DEFAULT 0 NOT NULL,
    verified_at timestamp with time zone,
    valid_from timestamp with time zone NOT NULL,
    valid_until timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: identity_party_binding; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.identity_party_binding (
    identity_id text NOT NULL,
    party_id text NOT NULL,
    tenant_id text NOT NULL,
    party_type text NOT NULL,
    binding_type text NOT NULL,
    valid_from text NOT NULL,
    valid_until text
);


--
-- Name: invitation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invitation (
    id text NOT NULL,
    tenant_id text NOT NULL,
    token_hash text NOT NULL,
    action text NOT NULL,
    scope text NOT NULL,
    target_id text NOT NULL,
    context jsonb NOT NULL,
    status text NOT NULL,
    delivery_state text NOT NULL,
    delivery_attempts integer DEFAULT 0 NOT NULL,
    usage_policy text NOT NULL,
    max_redemptions integer,
    usage_count integer DEFAULT 0 NOT NULL,
    outcome_ref jsonb,
    recipient_ref jsonb,
    origin_kind text,
    origin_id text,
    channel_preferences jsonb NOT NULL,
    batch_id text,
    ceremony_id text,
    created_at timestamp with time zone NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    delivered_at timestamp with time zone,
    first_opened_at timestamp with time zone,
    last_action_at timestamp with time zone,
    claimed_at timestamp with time zone,
    expired_at timestamp with time zone,
    failed_at timestamp with time zone,
    revoked_at timestamp with time zone,
    failure_reason text
);


--
-- Name: invitation_batch; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invitation_batch (
    id text NOT NULL,
    tenant_id text NOT NULL,
    created_at timestamp with time zone NOT NULL,
    created_by text,
    source jsonb NOT NULL,
    total integer NOT NULL,
    minted integer DEFAULT 0 NOT NULL,
    delivered integer DEFAULT 0 NOT NULL,
    failed integer DEFAULT 0 NOT NULL,
    state text NOT NULL,
    completed_at timestamp with time zone
);


--
-- Name: invitation_event; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invitation_event (
    id text NOT NULL,
    invitation_id text NOT NULL,
    tenant_id text NOT NULL,
    type text NOT NULL,
    occurred_at timestamp with time zone NOT NULL,
    actor_kind text,
    actor_id text,
    payload jsonb
);


--
-- Name: invitation_hmac_key; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invitation_hmac_key (
    tenant_id text NOT NULL,
    key_id text NOT NULL,
    algorithm text NOT NULL,
    wrapped_dek text NOT NULL,
    kek_alias text NOT NULL,
    created_at timestamp with time zone NOT NULL,
    rotated_from_id text
);


--
-- Name: issuer; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.issuer (
    party_id text NOT NULL
);


--
-- Name: issuer_credential_definition; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.issuer_credential_definition (
    credential_definition_id text NOT NULL
);


--
-- Name: key_reference; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.key_reference (
    id text NOT NULL,
    tenant_id text NOT NULL,
    alias text NOT NULL,
    kid text,
    provider_id text NOT NULL,
    origin text DEFAULT 'managed'::text NOT NULL,
    key_type text,
    signature_algorithm text,
    key_visibility text,
    key_encoding text,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text,
    public_key_jwk text,
    control_mode text DEFAULT 'platform_managed'::text NOT NULL,
    wallet_unit_id text
);


--
-- Name: kms_secret_payload; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.kms_secret_payload (
    address_digest text NOT NULL,
    consumer_tenant_id text NOT NULL,
    definition_id text NOT NULL,
    revision bigint NOT NULL,
    tenant_binding_id text,
    encrypted_envelope bytea NOT NULL,
    envelope_digest text NOT NULL,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    CONSTRAINT kms_secret_payload_address_digest_check CHECK ((address_digest ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT kms_secret_payload_encrypted_envelope_check CHECK ((octet_length(encrypted_envelope) > 0)),
    CONSTRAINT kms_secret_payload_envelope_digest_check CHECK ((envelope_digest ~ '^sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT kms_secret_payload_revision_check CHECK ((revision > 0)),
    CONSTRAINT kms_secret_payload_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY public.kms_secret_payload FORCE ROW LEVEL SECURITY;


--
-- Name: kv_entry; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.kv_entry (
    id text NOT NULL,
    store_id text NOT NULL,
    tenant_id text NOT NULL,
    principal_id text,
    session_id text,
    namespace text NOT NULL,
    entry_key text NOT NULL,
    entry_value bytea NOT NULL,
    expires_at timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: kv_version; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.kv_version (
    id text NOT NULL,
    stream_id text NOT NULL,
    entry_value bytea NOT NULL,
    expires_at_epoch_ms bigint,
    created_at_epoch_ms bigint NOT NULL
);


--
-- Name: kv_version_link; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.kv_version_link (
    stream_id text NOT NULL,
    version_id text NOT NULL,
    previous_version_id text,
    parent_slot text NOT NULL,
    CONSTRAINT ck_kv_version_parent_slot CHECK ((((previous_version_id IS NULL) AND (parent_slot = ''::text)) OR ((previous_version_id IS NOT NULL) AND (parent_slot = previous_version_id))))
);


--
-- Name: kv_versioned_stream; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.kv_versioned_stream (
    id text NOT NULL,
    store_id text NOT NULL,
    tenant_id text NOT NULL,
    principal_id text NOT NULL,
    session_id text NOT NULL,
    namespace text NOT NULL,
    entry_key text NOT NULL,
    head_version_id text,
    created_at_epoch_ms bigint NOT NULL,
    updated_at_epoch_ms bigint NOT NULL
);


--
-- Name: license_runtime_state; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.license_runtime_state (
    state_key text NOT NULL,
    last_good_snapshot_json text,
    last_seen_time text,
    updated_at text NOT NULL
);


--
-- Name: lote_draft; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lote_draft (
    tenant_id text NOT NULL,
    domain_id text NOT NULL,
    lote_id text NOT NULL,
    profile text NOT NULL,
    state text NOT NULL,
    sequence_number bigint NOT NULL,
    providers_json text NOT NULL,
    etag text NOT NULL,
    version bigint NOT NULL,
    managed_by text NOT NULL,
    validated_by text,
    updated_at bigint,
    CONSTRAINT lote_draft_profile_check CHECK ((profile = ANY (ARRAY['PID_PROVIDER'::text, 'WALLET_PROVIDER'::text, 'PUB_EAA_PROVIDER'::text, 'ACCESS_CA'::text, 'REGISTRATION_CERTIFICATE_PROVIDER'::text])))
);


--
-- Name: lote_published_version; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lote_published_version (
    tenant_id text NOT NULL,
    domain_id text NOT NULL,
    lote_id text NOT NULL,
    profile text NOT NULL,
    version bigint NOT NULL,
    sequence_number bigint NOT NULL,
    state text NOT NULL,
    exact_payload_bytes bytea NOT NULL,
    signed_artifact_bytes bytea NOT NULL,
    publication text NOT NULL,
    publication_reference text NOT NULL,
    receipt_version bigint NOT NULL,
    receipt_sequence_number bigint NOT NULL,
    signer_key_reference text NOT NULL,
    etag text NOT NULL,
    published_at bigint NOT NULL,
    valid_from bigint NOT NULL,
    next_update bigint NOT NULL,
    published_by text NOT NULL,
    providers_json text NOT NULL,
    CONSTRAINT lote_published_version_profile_check CHECK ((profile = ANY (ARRAY['PID_PROVIDER'::text, 'WALLET_PROVIDER'::text, 'PUB_EAA_PROVIDER'::text, 'ACCESS_CA'::text, 'REGISTRATION_CERTIFICATE_PROVIDER'::text])))
);


--
-- Name: lote_remote_provider_entry; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lote_remote_provider_entry (
    tenant_id text NOT NULL,
    domain_id text NOT NULL,
    source_id text NOT NULL,
    snapshot_id text NOT NULL,
    country text NOT NULL,
    provider_id text NOT NULL,
    name text NOT NULL,
    service_type text NOT NULL,
    service_status text NOT NULL,
    profile text NOT NULL,
    service_supply_points_json text NOT NULL,
    certificate_chain_base64_json text NOT NULL,
    CONSTRAINT lote_remote_provider_entry_profile_check CHECK ((profile = ANY (ARRAY['PID_PROVIDER'::text, 'WALLET_PROVIDER'::text, 'PUB_EAA_PROVIDER'::text, 'ACCESS_CA'::text, 'REGISTRATION_CERTIFICATE_PROVIDER'::text])))
);


--
-- Name: lote_remote_refresh_attempt; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lote_remote_refresh_attempt (
    tenant_id text NOT NULL,
    domain_id text NOT NULL,
    source_id text NOT NULL,
    attempt_id text NOT NULL,
    revision bigint NOT NULL,
    state text NOT NULL,
    started_at bigint NOT NULL,
    completed_at bigint,
    resulting_snapshot_id text,
    diagnostic_codes_json text NOT NULL,
    CONSTRAINT lote_remote_refresh_attempt_state_check CHECK ((state = ANY (ARRAY['STARTED'::text, 'SUCCEEDED'::text, 'FAILED'::text])))
);


--
-- Name: lote_remote_revision; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lote_remote_revision (
    tenant_id text NOT NULL,
    domain_id text NOT NULL,
    source_id text NOT NULL,
    revision bigint NOT NULL,
    profile text NOT NULL,
    url text NOT NULL,
    verification_trust_anchor_ids_json text NOT NULL,
    allowed_hosts_json text NOT NULL,
    max_artifact_bytes bigint NOT NULL,
    state text NOT NULL,
    etag text NOT NULL,
    managed_by text NOT NULL,
    managed_at bigint NOT NULL,
    validation_indication text,
    validation_by text,
    validation_at bigint,
    validation_snapshot_id text,
    validation_sub_indications_json text,
    CONSTRAINT lote_remote_revision_profile_check CHECK ((profile = ANY (ARRAY['PID_PROVIDER'::text, 'WALLET_PROVIDER'::text, 'PUB_EAA_PROVIDER'::text, 'ACCESS_CA'::text, 'REGISTRATION_CERTIFICATE_PROVIDER'::text]))),
    CONSTRAINT lote_remote_revision_state_check CHECK ((state = ANY (ARRAY['CANDIDATE'::text, 'VALIDATED'::text, 'REJECTED'::text, 'SUPERSEDED'::text])))
);


--
-- Name: lote_remote_snapshot; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lote_remote_snapshot (
    tenant_id text NOT NULL,
    domain_id text NOT NULL,
    source_id text NOT NULL,
    revision bigint NOT NULL,
    snapshot_id text NOT NULL,
    profile text NOT NULL,
    artifact_digest text NOT NULL,
    exact_artifact_bytes bytea NOT NULL,
    signed_issue_time bigint NOT NULL,
    signed_next_update bigint NOT NULL,
    sequence_number bigint NOT NULL,
    stored_by text NOT NULL,
    stored_at bigint NOT NULL,
    CONSTRAINT lote_remote_snapshot_profile_check CHECK ((profile = ANY (ARRAY['PID_PROVIDER'::text, 'WALLET_PROVIDER'::text, 'PUB_EAA_PROVIDER'::text, 'ACCESS_CA'::text, 'REGISTRATION_CERTIFICATE_PROVIDER'::text])))
);


--
-- Name: lote_remote_source; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lote_remote_source (
    tenant_id text NOT NULL,
    domain_id text NOT NULL,
    source_id text NOT NULL,
    profile text NOT NULL,
    enabled boolean NOT NULL,
    active_revision bigint,
    active_snapshot_id text,
    managed_by text NOT NULL,
    managed_at bigint NOT NULL,
    etag text NOT NULL,
    CONSTRAINT lote_remote_source_profile_check CHECK ((profile = ANY (ARRAY['PID_PROVIDER'::text, 'WALLET_PROVIDER'::text, 'PUB_EAA_PROVIDER'::text, 'ACCESS_CA'::text, 'REGISTRATION_CERTIFICATE_PROVIDER'::text])))
);


--
-- Name: mdoc_vical_configuration; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mdoc_vical_configuration (
    domain_id text NOT NULL,
    anchor_id text NOT NULL,
    url text NOT NULL,
    signer_anchor_ids_json text NOT NULL,
    issuer_anchor_ids_json text NOT NULL,
    required_certificate_profiles_json text NOT NULL,
    enabled boolean NOT NULL,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    tenant_id text,
    CONSTRAINT mdoc_vical_configuration_url_check CHECK (((substr(url, 1, 8) = 'https://'::text) AND (length(url) > 8) AND (substr(url, 9, 1) <> ALL (ARRAY['/'::text, ':'::text, '@'::text])) AND (strpos(url, '@'::text) = 0) AND (strpos(url, '#'::text) = 0)))
);


--
-- Name: metadata_snapshot; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.metadata_snapshot (
    id text NOT NULL,
    tenant_id text NOT NULL,
    software_party_id text NOT NULL,
    capability_id text,
    snapshot_type text NOT NULL,
    document jsonb NOT NULL,
    discovered_from text,
    discovered_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone NOT NULL,
    created_by_id text
);


--
-- Name: natural_person; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.natural_person (
    party_id text NOT NULL,
    first_name text,
    middle_name text,
    last_name text,
    birth_date date
);


--
-- Name: oauth2_as_capability; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oauth2_as_capability (
    capability_id text NOT NULL,
    authorization_server_kind text
);


--
-- Name: oauth_client_registration; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oauth_client_registration (
    tenant_id text NOT NULL,
    authorization_server_id text NOT NULL,
    client_id text NOT NULL,
    status text NOT NULL,
    client_secret_hash text,
    secret_resource_handle text,
    secret_record_version bigint,
    registered_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    registration_json text NOT NULL,
    CONSTRAINT oauth_client_registration_check CHECK (((secret_resource_handle IS NULL) = (secret_record_version IS NULL)))
);


--
-- Name: oauth_signing_key; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oauth_signing_key (
    kid text NOT NULL,
    tenant_id text NOT NULL,
    algorithm text NOT NULL,
    state text NOT NULL,
    priority integer NOT NULL,
    created_at timestamp with time zone NOT NULL,
    not_before timestamp with time zone NOT NULL,
    kms_alias text NOT NULL,
    kms_provider_id text NOT NULL
);


--
-- Name: oauth_signing_key_revision; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oauth_signing_key_revision (
    tenant_id text NOT NULL,
    revision bigint NOT NULL,
    CONSTRAINT oauth_signing_key_revision_revision_check CHECK ((revision > 0))
);


--
-- Name: oid4vci_authorization_server_override; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oid4vci_authorization_server_override (
    id text NOT NULL,
    tenant_id text NOT NULL,
    issuer_capability_id text NOT NULL,
    resource_kind text NOT NULL,
    resource_id text NOT NULL,
    authorization_server_id text,
    allowed_grant_types jsonb,
    revision bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    CONSTRAINT ck_oaso_kind CHECK ((resource_kind = ANY (ARRAY['CREDENTIAL_CONFIGURATION'::text, 'ISSUANCE_TEMPLATE'::text]))),
    CONSTRAINT ck_oaso_revision CHECK ((revision >= 0))
);


--
-- Name: oid4vci_issuer; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oid4vci_issuer (
    party_id text NOT NULL
);


--
-- Name: oid4vci_issuer_authorization_server_binding; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oid4vci_issuer_authorization_server_binding (
    id text NOT NULL,
    tenant_id text NOT NULL,
    issuer_capability_id text NOT NULL,
    authorization_server_id text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    display_order integer DEFAULT 0 NOT NULL,
    grant_policy jsonb DEFAULT '{}'::jsonb NOT NULL,
    revision bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text,
    CONSTRAINT ck_oiasb_order CHECK ((display_order >= 0)),
    CONSTRAINT ck_oiasb_revision CHECK ((revision >= 0))
);


--
-- Name: oid4vci_issuer_capability; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oid4vci_issuer_capability (
    capability_id text NOT NULL,
    authorization_server_capability_id text
);


--
-- Name: oid4vci_issuer_protocol_profile; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oid4vci_issuer_protocol_profile (
    id text NOT NULL,
    tenant_id text NOT NULL,
    issuer_capability_id text NOT NULL,
    profile text DEFAULT 'OID4VCI_1_0_FINAL'::text NOT NULL,
    revision bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text,
    CONSTRAINT ck_oipp_profile CHECK ((profile = ANY (ARRAY['OID4VCI_1_0_FINAL'::text, 'OID4VCI_1_1_DRAFT_2A1F0513'::text]))),
    CONSTRAINT ck_oipp_revision CHECK ((revision >= 0))
);


--
-- Name: oid4vci_offer_session_event; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oid4vci_offer_session_event (
    tenant_id text NOT NULL,
    instance_id text NOT NULL,
    protocol_session_id text NOT NULL,
    source_event_id text NOT NULL,
    sequence bigint NOT NULL,
    event_type text NOT NULL,
    occurred_at timestamp with time zone NOT NULL,
    old_state text,
    new_state text,
    safe_metadata text,
    redacted_diagnostic_detail text,
    correlation_id text
);


--
-- Name: oid4vci_offer_session_projection; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oid4vci_offer_session_projection (
    tenant_id text NOT NULL,
    instance_id text NOT NULL,
    protocol_session_id text NOT NULL,
    current_state text,
    template_id text,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    last_sequence bigint NOT NULL,
    creation_snapshot text,
    current_result text,
    safe_metadata text,
    redacted_diagnostic_detail text,
    correlation_id text
);


--
-- Name: oid4vci_override_projection_outbox; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oid4vci_override_projection_outbox (
    id text NOT NULL,
    tenant_id text NOT NULL,
    override_id text NOT NULL,
    issuer_capability_id text NOT NULL,
    resource_kind text NOT NULL,
    resource_id text NOT NULL,
    before_revision bigint NOT NULL,
    after_revision bigint NOT NULL,
    authorization_server_id text,
    allowed_grant_types jsonb,
    actor_id text,
    occurred_at timestamp with time zone NOT NULL,
    delivery_status text DEFAULT 'PENDING'::text NOT NULL,
    attempt_count integer DEFAULT 0 NOT NULL,
    next_attempt_at timestamp with time zone NOT NULL,
    last_error text,
    delivered_at timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT ck_oopo_attempts CHECK ((attempt_count >= 0)),
    CONSTRAINT ck_oopo_delivery CHECK ((delivery_status = ANY (ARRAY['PENDING'::text, 'DELIVERED'::text]))),
    CONSTRAINT ck_oopo_kind CHECK ((resource_kind = ANY (ARRAY['CREDENTIAL_CONFIGURATION'::text, 'ISSUANCE_TEMPLATE'::text]))),
    CONSTRAINT ck_oopo_revision CHECK (((before_revision >= 0) AND (after_revision = (before_revision + 1))))
);


--
-- Name: oid4vci_profile_audit_outbox; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oid4vci_profile_audit_outbox (
    id text NOT NULL,
    tenant_id text NOT NULL,
    idempotency_key text NOT NULL,
    issuer_capability_id text NOT NULL,
    event_type text NOT NULL,
    before_profile text NOT NULL,
    before_revision bigint NOT NULL,
    after_profile text NOT NULL,
    after_revision bigint NOT NULL,
    actor_id text,
    reason text NOT NULL,
    occurred_at timestamp with time zone NOT NULL,
    delivery_status text DEFAULT 'PENDING'::text NOT NULL,
    attempt_count integer DEFAULT 0 NOT NULL,
    next_attempt_at timestamp with time zone NOT NULL,
    last_error text,
    delivered_at timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT ck_opao_attempts CHECK ((attempt_count >= 0)),
    CONSTRAINT ck_opao_delivered CHECK ((((delivery_status = 'PENDING'::text) AND (delivered_at IS NULL)) OR ((delivery_status = 'DELIVERED'::text) AND (delivered_at IS NOT NULL)))),
    CONSTRAINT ck_opao_delivery CHECK ((delivery_status = ANY (ARRAY['PENDING'::text, 'DELIVERED'::text]))),
    CONSTRAINT ck_opao_event CHECK ((event_type = 'OID4VCI_ISSUER_PROFILE_UPGRADED'::text)),
    CONSTRAINT ck_opao_profiles CHECK (((before_profile = ANY (ARRAY['OID4VCI_1_0_FINAL'::text, 'OID4VCI_1_1_DRAFT_2A1F0513'::text])) AND (after_profile = ANY (ARRAY['OID4VCI_1_0_FINAL'::text, 'OID4VCI_1_1_DRAFT_2A1F0513'::text])))),
    CONSTRAINT ck_opao_revision CHECK (((before_revision >= 0) AND (after_revision = (before_revision + 1))))
);


--
-- Name: oid4vp_auth_session; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oid4vp_auth_session (
    session_id text NOT NULL,
    correlation_id text NOT NULL,
    oauth_session_id text,
    query_id text NOT NULL,
    resolved_user_id text,
    error_message text
);


--
-- Name: oid4vp_authorization_session_event; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oid4vp_authorization_session_event (
    tenant_id text NOT NULL,
    instance_id text NOT NULL,
    protocol_session_id text NOT NULL,
    source_event_id text NOT NULL,
    sequence bigint NOT NULL,
    event_type text NOT NULL,
    occurred_at timestamp with time zone NOT NULL,
    old_state text,
    new_state text,
    safe_metadata text,
    redacted_diagnostic_detail text,
    correlation_id text
);


--
-- Name: oid4vp_authorization_session_projection; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oid4vp_authorization_session_projection (
    tenant_id text NOT NULL,
    instance_id text NOT NULL,
    protocol_session_id text NOT NULL,
    current_state text,
    template_id text,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    last_sequence bigint NOT NULL,
    creation_snapshot text,
    current_result text,
    safe_metadata text,
    redacted_diagnostic_detail text,
    correlation_id text
);


--
-- Name: oid4vp_verifier; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oid4vp_verifier (
    party_id text NOT NULL
);


--
-- Name: oid4vp_verifier_capability; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oid4vp_verifier_capability (
    capability_id text NOT NULL,
    authorization_server_capability_id text
);


--
-- Name: organization; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organization (
    party_id text NOT NULL,
    legal_name text NOT NULL,
    organization_type text,
    industry text,
    contact_email text,
    website_url text,
    privacy_policy_uri text,
    tos_uri text
);


--
-- Name: organization_registration; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organization_registration (
    id text NOT NULL,
    tenant_id text NOT NULL,
    organization_id text NOT NULL,
    registration_type text NOT NULL,
    value_ text NOT NULL,
    issuing_authority text,
    jurisdiction_country text,
    valid_from timestamp with time zone,
    valid_until timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text
);


--
-- Name: organization_unit; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organization_unit (
    party_id text NOT NULL,
    tenant_id text NOT NULL,
    parent_ou_id text,
    name text NOT NULL,
    tos_uri text,
    branding jsonb,
    ou_inheritance_policy text DEFAULT 'READ_ONLY_ANCESTOR'::text NOT NULL,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: party; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.party (
    id text NOT NULL,
    tenant_id text NOT NULL,
    party_type text NOT NULL,
    origin text,
    display_name text NOT NULL,
    uri text,
    jurisdiction text,
    owner_id text,
    organization_unit_id text,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: party_external_relationship; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.party_external_relationship (
    id text NOT NULL,
    tenant_id text NOT NULL,
    party_id text NOT NULL,
    relationship_type text NOT NULL,
    external_system text NOT NULL,
    external_type text NOT NULL,
    external_id text NOT NULL,
    source_id text,
    status text NOT NULL,
    valid_from timestamp with time zone,
    valid_until timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: party_relationship; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.party_relationship (
    id text NOT NULL,
    tenant_id text NOT NULL,
    left_party_id text NOT NULL,
    right_party_id text NOT NULL,
    relationship_type text NOT NULL,
    status text NOT NULL,
    valid_from timestamp with time zone,
    valid_until timestamp with time zone,
    verified_at timestamp with time zone,
    verified_by_id text,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text
);


--
-- Name: party_specialization; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.party_specialization (
    party_id text NOT NULL,
    tenant_id text NOT NULL,
    subtype text NOT NULL,
    profile_id text,
    profile_version text,
    organization_unit_id text,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: physical_address; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.physical_address (
    id text NOT NULL,
    party_id text NOT NULL,
    identifier_id text,
    tenant_id text NOT NULL,
    address_type text NOT NULL,
    label text,
    is_primary integer DEFAULT 0 NOT NULL,
    street_address text,
    city text,
    province text,
    postal_code text,
    country_code text,
    latitude real,
    longitude real,
    valid_from timestamp with time zone NOT NULL,
    valid_until timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: platform_bootstrap_credential; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_bootstrap_credential (
    credential_id text NOT NULL,
    purpose text NOT NULL,
    encrypted_envelope bytea NOT NULL,
    kek_identity text NOT NULL,
    kek_version bigint NOT NULL,
    envelope_version bigint NOT NULL,
    generation bigint NOT NULL,
    lifecycle_state text NOT NULL,
    version bigint NOT NULL,
    created_by_actor_id text NOT NULL,
    updated_by_actor_id text NOT NULL,
    correlation_id text NOT NULL,
    rotated_from_generation bigint,
    rotation_reason text,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    CONSTRAINT platform_bootstrap_credential_envelope_version_check CHECK ((envelope_version > 0)),
    CONSTRAINT platform_bootstrap_credential_generation_check CHECK ((generation > 0)),
    CONSTRAINT platform_bootstrap_credential_lifecycle_state_check CHECK ((lifecycle_state = ANY (ARRAY['CANDIDATE'::text, 'READY'::text, 'ACTIVE'::text, 'SUSPENDED'::text, 'RETAINED'::text, 'RETIRED'::text, 'PURGED'::text, 'FAILED'::text]))),
    CONSTRAINT platform_bootstrap_credential_rotated_from_generation_check CHECK (((rotated_from_generation IS NULL) OR (rotated_from_generation > 0))),
    CONSTRAINT platform_bootstrap_credential_version_check CHECK ((version > 0))
);


--
-- Name: platform_bootstrap_credential_generation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_bootstrap_credential_generation (
    credential_id text NOT NULL,
    generation bigint NOT NULL,
    created_at bigint NOT NULL,
    CONSTRAINT platform_bootstrap_credential_generation_generation_check CHECK ((generation > 0))
);

ALTER TABLE ONLY public.platform_bootstrap_credential_generation FORCE ROW LEVEL SECURITY;


--
-- Name: platform_secret_provider_offering; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_secret_provider_offering (
    offering_id text NOT NULL,
    definition_id text NOT NULL,
    published_revision bigint NOT NULL,
    display_name text NOT NULL,
    enabled boolean NOT NULL,
    assignment_count bigint DEFAULT 0 NOT NULL,
    lifecycle_state text NOT NULL,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    CONSTRAINT platform_secret_provider_offering_assignment_count_check CHECK ((assignment_count >= 0)),
    CONSTRAINT platform_secret_provider_offering_lifecycle_state_check CHECK ((lifecycle_state = ANY (ARRAY['CANDIDATE'::text, 'READY'::text, 'ACTIVE'::text, 'SUSPENDED'::text, 'RETAINED'::text, 'RETIRED'::text, 'PURGED'::text, 'FAILED'::text]))),
    CONSTRAINT platform_secret_provider_offering_version_check CHECK ((version > 0))
);


--
-- Name: policy_assignment; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.policy_assignment (
    id text NOT NULL,
    tenant_id text NOT NULL,
    policy_id text NOT NULL,
    category_id text,
    group_id text,
    resource_id text,
    is_default boolean NOT NULL,
    priority bigint NOT NULL,
    valid_from timestamp with time zone,
    valid_until timestamp with time zone,
    created_by_id text,
    updated_by_id text,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: quota_counter; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quota_counter (
    scope text NOT NULL,
    scope_id text NOT NULL,
    quota_key text NOT NULL,
    window_start timestamp with time zone NOT NULL,
    count_value bigint DEFAULT 0 NOT NULL
);


--
-- Name: relationship_employment; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.relationship_employment (
    relationship_id text NOT NULL,
    job_title text,
    department text,
    employee_number text,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: relationship_type; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.relationship_type (
    type text NOT NULL,
    left_to_right_i18n_key text NOT NULL,
    right_to_left_i18n_key text NOT NULL,
    description_i18n_key text
);


--
-- Name: requirement_category; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.requirement_category (
    id text NOT NULL,
    tenant_id text NOT NULL,
    name text NOT NULL,
    slug text NOT NULL,
    description text,
    is_active boolean NOT NULL,
    display_order bigint,
    created_by_id text,
    updated_by_id text,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: resource; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resource (
    party_id text NOT NULL,
    resource_category_id text NOT NULL,
    resource_group_id text,
    description text,
    image_asset_id text,
    location_label text,
    timezone text,
    status text NOT NULL,
    capacity bigint
);


--
-- Name: resource_category; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resource_category (
    id text NOT NULL,
    tenant_id text NOT NULL,
    name text NOT NULL,
    slug text NOT NULL,
    description text,
    icon_asset_id text,
    schema_definition_id text,
    parent_category_id text,
    is_active boolean NOT NULL,
    display_order bigint,
    created_by_id text,
    updated_by_id text,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: resource_group; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resource_group (
    id text NOT NULL,
    tenant_id text NOT NULL,
    name text NOT NULL,
    description text,
    category_id text,
    image_asset_id text,
    status text NOT NULL,
    created_by_id text,
    updated_by_id text,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: resource_requirement; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resource_requirement (
    id text NOT NULL,
    tenant_id text NOT NULL,
    resource_id text NOT NULL,
    requirement_category_id text,
    credential_definition_id text,
    presentation_definition_id text,
    dcql_query text,
    sub_identifier text,
    description text,
    is_mandatory boolean NOT NULL,
    display_order bigint,
    created_by_id text,
    updated_by_id text,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: resource_schedule; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resource_schedule (
    id text NOT NULL,
    tenant_id text NOT NULL,
    resource_id text NOT NULL,
    day_of_week bigint,
    day_of_month bigint,
    month bigint,
    specific_date date,
    start_time time without time zone,
    end_time time without time zone,
    is_closed boolean NOT NULL,
    valid_from timestamp with time zone,
    valid_until timestamp with time zone,
    created_by_id text,
    updated_by_id text,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: resource_usage_policy; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resource_usage_policy (
    id text NOT NULL,
    tenant_id text NOT NULL,
    resource_id text NOT NULL,
    usage_policy_id text NOT NULL,
    priority bigint NOT NULL,
    override_concurrency boolean NOT NULL,
    concurrency_limit_override bigint,
    effective_from timestamp with time zone,
    effective_until timestamp with time zone,
    created_by_id text,
    updated_by_id text,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: role; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.role (
    id text NOT NULL,
    tenant_id text NOT NULL,
    name text NOT NULL,
    description text,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: schedule_rule; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schedule_rule (
    id text NOT NULL,
    schedule_set_id text NOT NULL,
    day_of_week bigint,
    day_of_month bigint,
    month bigint,
    specific_date date,
    nth_weekday bigint,
    start_time time without time zone NOT NULL,
    end_time time without time zone NOT NULL,
    is_closed boolean NOT NULL,
    valid_from timestamp with time zone,
    valid_until timestamp with time zone,
    created_by_id text,
    updated_by_id text,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: schedule_set; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schedule_set (
    id text NOT NULL,
    tenant_id text NOT NULL,
    name text NOT NULL,
    description text,
    priority bigint NOT NULL,
    is_default boolean NOT NULL,
    created_by_id text,
    updated_by_id text,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: schedule_set_assignment; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schedule_set_assignment (
    id text NOT NULL,
    tenant_id text NOT NULL,
    schedule_set_id text NOT NULL,
    category_id text,
    group_id text,
    resource_id text,
    is_default boolean NOT NULL,
    priority bigint NOT NULL,
    valid_from timestamp with time zone,
    valid_until timestamp with time zone,
    created_by_id text,
    updated_by_id text,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: schedule_set_inclusion; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schedule_set_inclusion (
    id text NOT NULL,
    parent_set_id text NOT NULL,
    included_set_id text NOT NULL,
    priority bigint NOT NULL,
    created_at timestamp with time zone NOT NULL
);


--
-- Name: schema_object; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_object (
    id text NOT NULL,
    type text NOT NULL,
    schema jsonb NOT NULL,
    tenant_id text NOT NULL,
    owner_id text,
    created_by_id text,
    created_at timestamp with time zone NOT NULL,
    updated_by_id text,
    updated_at timestamp with time zone NOT NULL,
    deleted_by_id text,
    deleted_at timestamp with time zone
);


--
-- Name: secret_access_grant; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_access_grant (
    actor_id text NOT NULL,
    tenant_id text NOT NULL,
    operation text NOT NULL,
    assignment_role text NOT NULL,
    purpose text NOT NULL,
    lifecycle_state text NOT NULL,
    version bigint NOT NULL,
    created_by_actor_id text NOT NULL,
    updated_by_actor_id text NOT NULL,
    correlation_id text NOT NULL,
    change_reason text NOT NULL,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    CONSTRAINT secret_access_grant_actor_id_check CHECK ((actor_id ~ '^[A-Za-z0-9][A-Za-z0-9._:@-]{0,255}$'::text)),
    CONSTRAINT secret_access_grant_assignment_role_check CHECK ((assignment_role = ANY (ARRAY['PLATFORM_STORAGE'::text, 'TENANT_SECRETS'::text]))),
    CONSTRAINT secret_access_grant_change_reason_check CHECK ((((length(change_reason) >= 1) AND (length(change_reason) <= 160)) AND (change_reason !~ '[*]'::text))),
    CONSTRAINT secret_access_grant_correlation_id_check CHECK ((((length(correlation_id) >= 1) AND (length(correlation_id) <= 256)) AND (correlation_id !~ '[*]'::text))),
    CONSTRAINT secret_access_grant_created_by_actor_id_check CHECK ((created_by_actor_id ~ '^[A-Za-z0-9][A-Za-z0-9._:@-]{0,255}$'::text)),
    CONSTRAINT secret_access_grant_lifecycle_state_check CHECK ((lifecycle_state = ANY (ARRAY['ACTIVE'::text, 'SUSPENDED'::text, 'RETIRED'::text]))),
    CONSTRAINT secret_access_grant_operation_check CHECK ((operation = ANY (ARRAY['READ'::text, 'CREATE'::text, 'ROTATE'::text, 'PURGE'::text, 'MIGRATE'::text]))),
    CONSTRAINT secret_access_grant_purpose_check CHECK ((purpose ~ '^[A-Za-z0-9][A-Za-z0-9._:@-]{0,119}$'::text)),
    CONSTRAINT secret_access_grant_tenant_id_check CHECK (((tenant_id ~ '^[A-Za-z0-9][A-Za-z0-9._:@-]{0,255}$'::text) AND (tenant_id <> '__platform__'::text))),
    CONSTRAINT secret_access_grant_updated_by_actor_id_check CHECK ((updated_by_actor_id ~ '^[A-Za-z0-9][A-Za-z0-9._:@-]{0,255}$'::text)),
    CONSTRAINT secret_access_grant_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY public.secret_access_grant FORCE ROW LEVEL SECURITY;


--
-- Name: secret_assignment_write_fence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_assignment_write_fence (
    assignment_id text NOT NULL,
    consumer_tenant_id text NOT NULL,
    migration_id text NOT NULL,
    fence bigint NOT NULL,
    lifecycle_state text NOT NULL,
    created_at bigint NOT NULL,
    released_at bigint,
    CONSTRAINT secret_assignment_write_fence_check CHECK (((lifecycle_state = 'RELEASED'::text) = (released_at IS NOT NULL))),
    CONSTRAINT secret_assignment_write_fence_fence_check CHECK ((fence > 0)),
    CONSTRAINT secret_assignment_write_fence_lifecycle_state_check CHECK ((lifecycle_state = ANY (ARRAY['ACTIVE'::text, 'RELEASED'::text])))
);

ALTER TABLE ONLY public.secret_assignment_write_fence FORCE ROW LEVEL SECURITY;


--
-- Name: secret_authority_grant; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_authority_grant (
    manifest_generation bigint NOT NULL,
    effective_actor_id text NOT NULL,
    authenticated_tenant_id text NOT NULL,
    target_tenant_scope text NOT NULL,
    authority_scope text NOT NULL,
    operation text NOT NULL,
    lifecycle_state text NOT NULL,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    retired_at bigint,
    CONSTRAINT secret_authority_grant_authenticated_tenant_id_check CHECK ((((length(authenticated_tenant_id) >= 1) AND (length(authenticated_tenant_id) <= 512)) AND (authenticated_tenant_id !~~ '%*%'::text))),
    CONSTRAINT secret_authority_grant_authority_scope_check CHECK ((authority_scope = ANY (ARRAY['PLATFORM'::text, 'TENANT_SELF'::text, 'TENANT_DELEGATED'::text]))),
    CONSTRAINT secret_authority_grant_check CHECK ((((authority_scope = 'PLATFORM'::text) AND (target_tenant_scope = '__platform__'::text)) OR ((authority_scope <> 'PLATFORM'::text) AND (target_tenant_scope <> '__platform__'::text)))),
    CONSTRAINT secret_authority_grant_check1 CHECK (((authority_scope <> 'TENANT_SELF'::text) OR (authenticated_tenant_id = target_tenant_scope))),
    CONSTRAINT secret_authority_grant_check2 CHECK ((((lifecycle_state = 'ACTIVE'::text) AND (retired_at IS NULL)) OR ((lifecycle_state = 'RETIRED'::text) AND (retired_at IS NOT NULL) AND (retired_at >= created_at)))),
    CONSTRAINT secret_authority_grant_effective_actor_id_check CHECK ((((length(effective_actor_id) >= 1) AND (length(effective_actor_id) <= 512)) AND (effective_actor_id !~~ '%*%'::text))),
    CONSTRAINT secret_authority_grant_lifecycle_state_check CHECK ((lifecycle_state = ANY (ARRAY['ACTIVE'::text, 'RETIRED'::text]))),
    CONSTRAINT secret_authority_grant_operation_check CHECK ((operation = ANY (ARRAY['CREATE_PROVIDER'::text, 'CREATE_PROVIDER_REVISION'::text, 'STAGE_PROVIDER_CREDENTIALS'::text, 'TEST_PROVIDER'::text, 'PREFLIGHT_PROVIDER'::text, 'MARK_PROVIDER_READY'::text, 'PUBLISH_OFFERING'::text, 'PREFLIGHT_OFFERING'::text, 'CREATE_TENANT_VALUE'::text, 'CREATE_SYSTEM_CREDENTIAL'::text, 'ROTATE_SYSTEM_CREDENTIAL'::text, 'START_MIGRATION'::text, 'RESUME_MIGRATION'::text, 'ROLLBACK_MIGRATION'::text, 'PURGE_MIGRATION'::text]))),
    CONSTRAINT secret_authority_grant_target_tenant_scope_check CHECK ((((length(target_tenant_scope) >= 1) AND (length(target_tenant_scope) <= 512)) AND (target_tenant_scope !~~ '%*%'::text))),
    CONSTRAINT secret_authority_grant_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY public.secret_authority_grant FORCE ROW LEVEL SECURITY;


--
-- Name: secret_authority_manifest; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_authority_manifest (
    generation bigint NOT NULL,
    manifest_digest text NOT NULL,
    authority_source text NOT NULL,
    lifecycle_state text NOT NULL,
    version bigint NOT NULL,
    activated_at bigint NOT NULL,
    retired_at bigint,
    CONSTRAINT secret_authority_manifest_authority_source_check CHECK ((authority_source = 'BOOTSTRAP'::text)),
    CONSTRAINT secret_authority_manifest_check CHECK ((((lifecycle_state = 'ACTIVE'::text) AND (retired_at IS NULL)) OR ((lifecycle_state = 'RETIRED'::text) AND (retired_at IS NOT NULL) AND (retired_at >= activated_at)))),
    CONSTRAINT secret_authority_manifest_generation_check CHECK ((generation > 0)),
    CONSTRAINT secret_authority_manifest_lifecycle_state_check CHECK ((lifecycle_state = ANY (ARRAY['ACTIVE'::text, 'RETIRED'::text]))),
    CONSTRAINT secret_authority_manifest_manifest_digest_check CHECK ((manifest_digest ~ '^sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT secret_authority_manifest_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY public.secret_authority_manifest FORCE ROW LEVEL SECURITY;


--
-- Name: secret_collection_version; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_collection_version (
    scope_kind text NOT NULL,
    scope_id text NOT NULL,
    collection_kind text NOT NULL,
    version bigint NOT NULL,
    policy_version bigint NOT NULL,
    updated_at bigint NOT NULL,
    CONSTRAINT secret_collection_version_check CHECK ((((scope_kind = 'PLATFORM'::text) AND (scope_id = '__platform__'::text)) OR ((scope_kind = 'TENANT'::text) AND (scope_id <> '__platform__'::text)))),
    CONSTRAINT secret_collection_version_collection_kind_check CHECK ((collection_kind = ANY (ARRAY['STORAGE_PROVIDER'::text, 'OFFERING_PROVIDER'::text, 'TENANT_PROVIDER'::text, 'SECRET_VALUE'::text, 'INTERNAL_SECRET'::text, 'MIGRATION'::text, 'TENANT_POLICY'::text]))),
    CONSTRAINT secret_collection_version_policy_version_check CHECK ((policy_version >= 0)),
    CONSTRAINT secret_collection_version_scope_kind_check CHECK ((scope_kind = ANY (ARRAY['PLATFORM'::text, 'TENANT'::text]))),
    CONSTRAINT secret_collection_version_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY public.secret_collection_version FORCE ROW LEVEL SECURITY;


--
-- Name: secret_credential_material_clear_field; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_credential_material_clear_field (
    transition_id text NOT NULL,
    credential_field text NOT NULL,
    CONSTRAINT secret_credential_material_clear_field_credential_field_check CHECK ((credential_field ~ '^[A-Za-z][A-Za-z0-9._-]{0,127}$'::text))
);

ALTER TABLE ONLY public.secret_credential_material_clear_field FORCE ROW LEVEL SECURITY;


--
-- Name: secret_credential_material_stage; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_credential_material_stage (
    transition_id text NOT NULL,
    definition_id text NOT NULL,
    revision bigint NOT NULL,
    scope_kind text NOT NULL,
    scope_id text NOT NULL,
    operation_kind text NOT NULL,
    authentication_mode text NOT NULL,
    expected_revision_version bigint NOT NULL,
    material_generation bigint NOT NULL,
    operation_state text NOT NULL,
    fence bigint NOT NULL,
    failure_code text,
    actor_id text NOT NULL,
    correlation_id text NOT NULL,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    CONSTRAINT secret_credential_material_stag_expected_revision_version_check CHECK ((expected_revision_version > 0)),
    CONSTRAINT secret_credential_material_stage_actor_id_check CHECK (((length(actor_id) >= 1) AND (length(actor_id) <= 256))),
    CONSTRAINT secret_credential_material_stage_correlation_id_check CHECK (((length(correlation_id) >= 1) AND (length(correlation_id) <= 256))),
    CONSTRAINT secret_credential_material_stage_fence_check CHECK ((fence > 0)),
    CONSTRAINT secret_credential_material_stage_material_generation_check CHECK ((material_generation > 0)),
    CONSTRAINT secret_credential_material_stage_operation_kind_check CHECK ((operation_kind = ANY (ARRAY['PROVIDER_CREDENTIAL_STAGE'::text, 'PROVIDER_CREDENTIAL_ROTATE'::text]))),
    CONSTRAINT secret_credential_material_stage_operation_state_check CHECK ((operation_state = ANY (ARRAY['REQUESTED'::text, 'PREFLIGHTING'::text, 'PREFLIGHTED'::text, 'COMMITTING'::text, 'COMMITTED'::text, 'FAILED'::text, 'CANCELLED'::text]))),
    CONSTRAINT secret_credential_material_stage_scope_kind_check CHECK ((scope_kind = ANY (ARRAY['PLATFORM_STORAGE'::text, 'PLATFORM_OFFERING'::text, 'TENANT_MANAGED'::text]))),
    CONSTRAINT secret_credential_material_stage_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY public.secret_credential_material_stage FORCE ROW LEVEL SECURITY;


--
-- Name: secret_credential_rotation_journal; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_credential_rotation_journal (
    rotation_id text NOT NULL,
    definition_id text NOT NULL,
    revision bigint NOT NULL,
    consumer_tenant_id text NOT NULL,
    provider_owner_scope text NOT NULL,
    tenant_binding_id text,
    from_generation bigint NOT NULL,
    to_generation bigint NOT NULL,
    operation_state text NOT NULL,
    fence bigint NOT NULL,
    idempotency_key_hash text NOT NULL,
    version bigint NOT NULL,
    CONSTRAINT secret_credential_rotation_journal_check CHECK ((to_generation > from_generation)),
    CONSTRAINT secret_credential_rotation_journal_check1 CHECK ((((provider_owner_scope = consumer_tenant_id) AND (tenant_binding_id IS NULL)) OR ((provider_owner_scope = '__platform__'::text) AND (consumer_tenant_id <> '__platform__'::text) AND (tenant_binding_id IS NOT NULL)))),
    CONSTRAINT secret_credential_rotation_journal_fence_check CHECK ((fence >= 0)),
    CONSTRAINT secret_credential_rotation_journal_from_generation_check CHECK ((from_generation > 0)),
    CONSTRAINT secret_credential_rotation_journal_operation_state_check CHECK ((operation_state = ANY (ARRAY['REQUESTED'::text, 'PREFLIGHTING'::text, 'PREFLIGHTED'::text, 'RUNNING'::text, 'FENCED'::text, 'VALIDATING'::text, 'COMMITTING'::text, 'COMMITTED'::text, 'RETAINED'::text, 'ROLLING_BACK'::text, 'ROLLED_BACK'::text, 'PURGING'::text, 'PURGED'::text, 'FAILED'::text, 'CANCELLED'::text]))),
    CONSTRAINT secret_credential_rotation_journal_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY public.secret_credential_rotation_journal FORCE ROW LEVEL SECURITY;


--
-- Name: secret_initial_tenant_assignment_journal; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_initial_tenant_assignment_journal (
    transition_id text NOT NULL,
    tenant_id text NOT NULL,
    preflight_id text NOT NULL,
    tenant_binding_id text NOT NULL,
    definition_id text NOT NULL,
    revision bigint NOT NULL,
    assignment_id text NOT NULL,
    operation_state text NOT NULL,
    fence bigint NOT NULL,
    actor_id text NOT NULL,
    correlation_id text NOT NULL,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    CONSTRAINT secret_initial_tenant_assignment_journal_assignment_id_check CHECK ((assignment_id ~ '^asn_[A-Za-z0-9_-]{20,128}$'::text)),
    CONSTRAINT secret_initial_tenant_assignment_journal_check CHECK (((revision > 0) AND (fence > 0) AND (version > 0))),
    CONSTRAINT secret_initial_tenant_assignment_journal_operation_state_check CHECK ((operation_state = ANY (ARRAY['REQUESTED'::text, 'COMMITTED'::text]))),
    CONSTRAINT secret_initial_tenant_assignment_journal_tenant_id_check CHECK ((tenant_id <> '__platform__'::text)),
    CONSTRAINT secret_initial_tenant_assignment_journal_transition_id_check CHECK ((transition_id ~ '^trn_[A-Za-z0-9_-]{20,128}$'::text))
);

ALTER TABLE ONLY public.secret_initial_tenant_assignment_journal FORCE ROW LEVEL SECURITY;


--
-- Name: secret_kms_resource_mutation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_kms_resource_mutation (
    mutation_id text NOT NULL,
    owner_tenant_id text NOT NULL,
    resource_instance_key text NOT NULL,
    operation_kind text NOT NULL,
    idempotency_key_mac text NOT NULL,
    canonical_request_mac text NOT NULL,
    expected_resource_version bigint,
    result_resource_version bigint NOT NULL,
    result_binding_generation bigint,
    result_secret_generation bigint,
    created_at bigint NOT NULL,
    CONSTRAINT secret_kms_resource_mutation_canonical_request_mac_check CHECK ((canonical_request_mac ~ '^hmac-sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT secret_kms_resource_mutation_check CHECK ((((result_binding_generation IS NULL) AND (result_secret_generation IS NULL)) OR ((result_binding_generation > 0) AND (result_secret_generation > 0)))),
    CONSTRAINT secret_kms_resource_mutation_expected_resource_version_check CHECK (((expected_resource_version IS NULL) OR (expected_resource_version > 0))),
    CONSTRAINT secret_kms_resource_mutation_idempotency_key_mac_check CHECK ((idempotency_key_mac ~ '^hmac-sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT secret_kms_resource_mutation_operation_kind_check CHECK ((operation_kind = ANY (ARRAY['CREATE_MANAGED'::text, 'ATTACH_EXISTING_REFERENCE'::text, 'CHANGE_REFERENCE'::text, 'ATTACH_CREDENTIAL_BINDING'::text]))),
    CONSTRAINT secret_kms_resource_mutation_result_resource_version_check CHECK ((result_resource_version > 0))
);

ALTER TABLE ONLY public.secret_kms_resource_mutation FORCE ROW LEVEL SECURITY;


--
-- Name: secret_kms_resource_mutation_binding_result; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_kms_resource_mutation_binding_result (
    mutation_id text NOT NULL,
    credential_slot text NOT NULL,
    binding_generation bigint NOT NULL,
    CONSTRAINT secret_kms_resource_mutation_binding_r_binding_generation_check CHECK ((binding_generation > 0)),
    CONSTRAINT secret_kms_resource_mutation_binding_resu_credential_slot_check CHECK ((credential_slot ~ '^[a-z][a-z0-9-]{0,119}$'::text))
);

ALTER TABLE ONLY public.secret_kms_resource_mutation_binding_result FORCE ROW LEVEL SECURITY;


--
-- Name: secret_kms_resource_mutation_result; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_kms_resource_mutation_result (
    mutation_id text NOT NULL,
    public_handle text NOT NULL,
    provider_definition_id text NOT NULL,
    provider_revision bigint NOT NULL,
    CONSTRAINT secret_kms_resource_mutation_resul_provider_definition_id_check CHECK (((length(provider_definition_id) >= 1) AND (length(provider_definition_id) <= 160))),
    CONSTRAINT secret_kms_resource_mutation_result_provider_revision_check CHECK ((provider_revision > 0)),
    CONSTRAINT secret_kms_resource_mutation_result_public_handle_check CHECK ((public_handle ~ '^krh_[A-Za-z0-9_-]{20,128}$'::text))
);

ALTER TABLE ONLY public.secret_kms_resource_mutation_result FORCE ROW LEVEL SECURITY;


--
-- Name: secret_kms_resource_public_handle; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_kms_resource_public_handle (
    public_handle text NOT NULL,
    owner_tenant_id text NOT NULL,
    resource_instance_key text NOT NULL,
    lifecycle_state text NOT NULL,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    CONSTRAINT secret_kms_resource_public_handle_lifecycle_state_check CHECK ((lifecycle_state = ANY (ARRAY['ACTIVE'::text, 'RETIRED'::text, 'FAILED'::text]))),
    CONSTRAINT secret_kms_resource_public_handle_owner_tenant_id_check CHECK ((owner_tenant_id <> '__platform__'::text)),
    CONSTRAINT secret_kms_resource_public_handle_public_handle_check CHECK ((public_handle ~ '^krh_[A-Za-z0-9_-]{20,128}$'::text)),
    CONSTRAINT secret_kms_resource_public_handle_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY public.secret_kms_resource_public_handle FORCE ROW LEVEL SECURITY;


--
-- Name: secret_kms_resource_record; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_kms_resource_record (
    owner_tenant_id text NOT NULL,
    resource_instance_key text NOT NULL,
    resource_kind text DEFAULT 'SOFTWARE'::text NOT NULL,
    display_name text DEFAULT 'KMS resource'::text NOT NULL,
    provider_id text NOT NULL,
    credential_ownership text NOT NULL,
    software_storage_mode text,
    software_key_store_file_name text,
    safe_configuration_version bigint DEFAULT 0 NOT NULL,
    aws_region text,
    aws_endpoint_url text,
    aws_application_id text,
    azure_vault_uri text,
    azure_application_id text,
    azure_tenant_id text,
    azure_client_id text,
    azure_hsm_type text,
    record_class text DEFAULT 'KMS_RESOURCE'::text NOT NULL,
    reference_locator text NOT NULL,
    reference_digest text NOT NULL,
    provider_definition_id text NOT NULL,
    provider_revision bigint NOT NULL,
    lifecycle_state text NOT NULL,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    declared_by_deployment boolean DEFAULT false NOT NULL,
    deployment_credential_secret_id text,
    CONSTRAINT secret_kms_resource_record_check CHECK (((deployment_credential_secret_id IS NULL) OR declared_by_deployment)),
    CONSTRAINT secret_kms_resource_record_credential_ownership_check CHECK ((credential_ownership = ANY (ARRAY['PRODUCT_MANAGED'::text, 'TENANT_SUPPLIED'::text]))),
    CONSTRAINT secret_kms_resource_record_deployment_credential_secret_i_check CHECK (((deployment_credential_secret_id IS NULL) OR (deployment_credential_secret_id ~ '^sec_[A-Za-z0-9_-]{16,128}$'::text))),
    CONSTRAINT secret_kms_resource_record_display_name_check CHECK (((length(display_name) >= 1) AND (length(display_name) <= 160))),
    CONSTRAINT secret_kms_resource_record_lifecycle_state_check CHECK ((lifecycle_state = ANY (ARRAY['ACTIVE'::text, 'DETACHED'::text, 'RETIRED'::text, 'FAILED'::text]))),
    CONSTRAINT secret_kms_resource_record_owner_tenant_id_check CHECK ((owner_tenant_id <> '__platform__'::text)),
    CONSTRAINT secret_kms_resource_record_provider_id_check CHECK ((provider_id ~ '^[a-z][a-z0-9-]{2,63}$'::text)),
    CONSTRAINT secret_kms_resource_record_record_class_check CHECK ((record_class = 'KMS_RESOURCE'::text)),
    CONSTRAINT secret_kms_resource_record_reference_digest_check CHECK ((reference_digest ~ '^sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT secret_kms_resource_record_reference_locator_check CHECK (((reference_locator ~ '^[A-Za-z0-9][A-Za-z0-9._:@/-]*$'::text) AND ((length(reference_locator) >= 1) AND (length(reference_locator) <= 512)))),
    CONSTRAINT secret_kms_resource_record_resource_instance_key_check CHECK (((length(resource_instance_key) >= 1) AND (length(resource_instance_key) <= 256))),
    CONSTRAINT secret_kms_resource_record_resource_kind_check CHECK ((resource_kind = ANY (ARRAY['SOFTWARE'::text, 'AZURE_KEY_VAULT'::text, 'AWS_KMS'::text]))),
    CONSTRAINT secret_kms_resource_record_safe_configuration_version_check CHECK ((safe_configuration_version = ANY (ARRAY[(0)::bigint, (1)::bigint]))),
    CONSTRAINT secret_kms_resource_record_storage_projection_check CHECK ((((resource_kind = 'SOFTWARE'::text) AND (credential_ownership = 'PRODUCT_MANAGED'::text) AND (software_storage_mode = ANY (ARRAY['MEMORY'::text, 'FILE'::text, 'UPLOADED_FILE'::text, 'MOUNTED_FILE'::text])) AND (((software_storage_mode = 'MEMORY'::text) AND (software_key_store_file_name IS NULL)) OR ((software_storage_mode = 'FILE'::text) AND (((software_key_store_file_name ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,114}[.](p12|jks)$'::text) AND (software_key_store_file_name !~~ '.%'::text) AND (software_key_store_file_name !~~ '%..%'::text)) OR ((software_key_store_file_name ~ '^@file[|][A-Za-z0-9][A-Za-z0-9._-]{0,114}[.](p12|jks)[|](pkcs12|jks)$'::text) AND (software_key_store_file_name !~~ '%..%'::text)))) OR ((software_storage_mode = 'UPLOADED_FILE'::text) AND (software_key_store_file_name ~ '^@uploaded[|](pkcs12|jks)$'::text)) OR ((software_storage_mode = 'MOUNTED_FILE'::text) AND (software_key_store_file_name ~ '^@mounted[|][A-Za-z0-9][A-Za-z0-9._:@-]{0,127}[|][A-Za-z0-9._/-]{1,255}[.](p12|jks)[|](pkcs12|jks)$'::text) AND (software_key_store_file_name !~~ '%..%'::text) AND (software_key_store_file_name !~~ '%//%'::text) AND (software_key_store_file_name !~~ '%\\%'::text)))) OR ((resource_kind = ANY (ARRAY['AZURE_KEY_VAULT'::text, 'AWS_KMS'::text])) AND (software_storage_mode IS NULL) AND (software_key_store_file_name IS NULL)))),
    CONSTRAINT secret_kms_resource_record_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY public.secret_kms_resource_record FORCE ROW LEVEL SECURITY;


--
-- Name: secret_kms_resource_sharing; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_kms_resource_sharing (
    owner_tenant_id text NOT NULL,
    resource_instance_key text NOT NULL,
    fulfillment text NOT NULL,
    suggested_default bigint DEFAULT 0 NOT NULL,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    CONSTRAINT secret_kms_resource_sharing_fulfillment_check CHECK ((fulfillment = ANY (ARRAY['TEMPLATE'::text, 'SHARED_INSTANCE'::text]))),
    CONSTRAINT secret_kms_resource_sharing_suggested_default_check CHECK ((suggested_default = ANY (ARRAY[(0)::bigint, (1)::bigint]))),
    CONSTRAINT secret_kms_resource_sharing_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY public.secret_kms_resource_sharing FORCE ROW LEVEL SECURITY;


--
-- Name: secret_kms_resource_sharing_tenant; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_kms_resource_sharing_tenant (
    owner_tenant_id text NOT NULL,
    resource_instance_key text NOT NULL,
    offered_tenant_id text NOT NULL,
    created_at bigint NOT NULL,
    CONSTRAINT secret_kms_resource_sharing_tenant_check CHECK ((offered_tenant_id <> owner_tenant_id)),
    CONSTRAINT secret_kms_resource_sharing_tenant_offered_tenant_id_check CHECK (((length(offered_tenant_id) >= 1) AND (length(offered_tenant_id) <= 160)))
);

ALTER TABLE ONLY public.secret_kms_resource_sharing_tenant FORCE ROW LEVEL SECURITY;


--
-- Name: secret_kms_resource_sharing_withdrawal; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_kms_resource_sharing_withdrawal (
    owner_tenant_id text NOT NULL,
    resource_instance_key text NOT NULL,
    offered_tenant_id text NOT NULL,
    withdrawn_at bigint NOT NULL,
    CONSTRAINT secret_kms_resource_sharing_withdrawal_check CHECK ((offered_tenant_id <> owner_tenant_id)),
    CONSTRAINT secret_kms_resource_sharing_withdrawal_offered_tenant_id_check CHECK (((length(offered_tenant_id) >= 1) AND (length(offered_tenant_id) <= 160)))
);

ALTER TABLE ONLY public.secret_kms_resource_sharing_withdrawal FORCE ROW LEVEL SECURITY;


--
-- Name: secret_migration_action_journal; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_migration_action_journal (
    transition_id text NOT NULL,
    migration_id text NOT NULL,
    consumer_tenant_id text NOT NULL,
    action_kind text NOT NULL,
    action_nonce_hash text NOT NULL,
    allocated_fence bigint NOT NULL,
    operation_state text NOT NULL,
    actor_id text NOT NULL,
    correlation_id text NOT NULL,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    completed_at bigint,
    CONSTRAINT secret_migration_action_journal_action_kind_check CHECK ((action_kind = ANY (ARRAY['RESUME'::text, 'ROLLBACK'::text, 'PURGE'::text]))),
    CONSTRAINT secret_migration_action_journal_action_nonce_hash_check CHECK ((action_nonce_hash ~ '^hmac-sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT secret_migration_action_journal_check CHECK (((allocated_fence > 0) AND (version > 0))),
    CONSTRAINT secret_migration_action_journal_check1 CHECK (((operation_state = 'COMMITTED'::text) = (completed_at IS NOT NULL))),
    CONSTRAINT secret_migration_action_journal_operation_state_check CHECK ((operation_state = ANY (ARRAY['REQUESTED'::text, 'COMMITTED'::text, 'FAILED'::text, 'CANCELLED'::text])))
);

ALTER TABLE ONLY public.secret_migration_action_journal FORCE ROW LEVEL SECURITY;


--
-- Name: secret_migration_item; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_migration_item (
    migration_id text NOT NULL,
    secret_id text NOT NULL,
    consumer_tenant_id text NOT NULL,
    secret_owner_tenant_id text NOT NULL,
    source_generation bigint NOT NULL,
    target_generation bigint,
    operation_state text NOT NULL,
    fence bigint NOT NULL,
    version bigint NOT NULL,
    CONSTRAINT secret_migration_item_fence_check CHECK ((fence >= 0)),
    CONSTRAINT secret_migration_item_operation_state_check CHECK ((operation_state = ANY (ARRAY['REQUESTED'::text, 'PREFLIGHTING'::text, 'PREFLIGHTED'::text, 'RUNNING'::text, 'FENCED'::text, 'VALIDATING'::text, 'COMMITTING'::text, 'COMMITTED'::text, 'RETAINED'::text, 'ROLLING_BACK'::text, 'ROLLED_BACK'::text, 'PURGING'::text, 'PURGED'::text, 'FAILED'::text, 'CANCELLED'::text]))),
    CONSTRAINT secret_migration_item_source_generation_check CHECK ((source_generation > 0)),
    CONSTRAINT secret_migration_item_target_generation_check CHECK (((target_generation IS NULL) OR (target_generation > 0))),
    CONSTRAINT secret_migration_item_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY public.secret_migration_item FORCE ROW LEVEL SECURITY;


--
-- Name: secret_migration_journal; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_migration_journal (
    migration_id text NOT NULL,
    consumer_tenant_id text NOT NULL,
    source_assignment_id text NOT NULL,
    target_definition_id text NOT NULL,
    target_revision bigint NOT NULL,
    target_assignment_id text NOT NULL,
    preflight_id text NOT NULL,
    operation_state text NOT NULL,
    fence bigint NOT NULL,
    checkpoint text NOT NULL,
    idempotency_key_hash text NOT NULL,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    CONSTRAINT secret_migration_journal_fence_check CHECK ((fence >= 0)),
    CONSTRAINT secret_migration_journal_migration_id_check CHECK ((migration_id ~ '^smg_[A-Za-z0-9_-]{20,128}$'::text)),
    CONSTRAINT secret_migration_journal_operation_state_check CHECK ((operation_state = ANY (ARRAY['REQUESTED'::text, 'PREFLIGHTING'::text, 'PREFLIGHTED'::text, 'RUNNING'::text, 'FENCED'::text, 'VALIDATING'::text, 'COMMITTING'::text, 'COMMITTED'::text, 'RETAINED'::text, 'ROLLING_BACK'::text, 'ROLLED_BACK'::text, 'PURGING'::text, 'PURGED'::text, 'FAILED'::text, 'CANCELLED'::text]))),
    CONSTRAINT secret_migration_journal_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY public.secret_migration_journal FORCE ROW LEVEL SECURITY;


--
-- Name: secret_offering_provisioning_journal; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_offering_provisioning_journal (
    transition_id text NOT NULL,
    tenant_id text NOT NULL,
    offering_id text NOT NULL,
    definition_id text NOT NULL,
    revision bigint NOT NULL,
    tenant_binding_id text NOT NULL,
    capability_generation bigint NOT NULL,
    operation_state text NOT NULL,
    capability_id text,
    opaque_partition text,
    revocation_receipt_id text,
    fence bigint NOT NULL,
    actor_id text NOT NULL,
    correlation_id text NOT NULL,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    CONSTRAINT secret_offering_provisioning_journal_check CHECK (((capability_generation > 0) AND (fence > 0) AND (version > 0))),
    CONSTRAINT secret_offering_provisioning_journal_check1 CHECK ((((capability_id IS NULL) AND (opaque_partition IS NULL) AND (revocation_receipt_id IS NULL)) OR ((capability_id IS NOT NULL) AND (opaque_partition IS NOT NULL) AND (revocation_receipt_id ~ '^rev_[A-Za-z0-9_-]{16,128}$'::text)))),
    CONSTRAINT secret_offering_provisioning_journal_operation_state_check CHECK ((operation_state = ANY (ARRAY['REQUESTED'::text, 'PREFLIGHTING'::text, 'PREFLIGHTED'::text, 'RUNNING'::text, 'FENCED'::text, 'VALIDATING'::text, 'COMMITTING'::text, 'COMMITTED'::text, 'RETAINED'::text, 'ROLLING_BACK'::text, 'ROLLED_BACK'::text, 'PURGING'::text, 'PURGED'::text, 'FAILED'::text, 'CANCELLED'::text]))),
    CONSTRAINT secret_offering_provisioning_journal_tenant_id_check CHECK ((tenant_id <> '__platform__'::text))
);

ALTER TABLE ONLY public.secret_offering_provisioning_journal FORCE ROW LEVEL SECURITY;


--
-- Name: secret_orphan_cleanup_journal; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_orphan_cleanup_journal (
    cleanup_id text NOT NULL,
    consumer_tenant_id text NOT NULL,
    operation_state text NOT NULL,
    fence bigint NOT NULL,
    cursor_value text,
    version bigint NOT NULL,
    CONSTRAINT secret_orphan_cleanup_journal_fence_check CHECK ((fence >= 0)),
    CONSTRAINT secret_orphan_cleanup_journal_operation_state_check CHECK ((operation_state = ANY (ARRAY['REQUESTED'::text, 'PREFLIGHTING'::text, 'PREFLIGHTED'::text, 'RUNNING'::text, 'FENCED'::text, 'VALIDATING'::text, 'COMMITTING'::text, 'COMMITTED'::text, 'RETAINED'::text, 'ROLLING_BACK'::text, 'ROLLED_BACK'::text, 'PURGING'::text, 'PURGED'::text, 'FAILED'::text, 'CANCELLED'::text]))),
    CONSTRAINT secret_orphan_cleanup_journal_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY public.secret_orphan_cleanup_journal FORCE ROW LEVEL SECURITY;


--
-- Name: secret_permit_replay_state; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_permit_replay_state (
    permit_id text NOT NULL,
    scope_digest text NOT NULL,
    replay_kind text NOT NULL,
    max_uses integer NOT NULL,
    consumed_uses integer NOT NULL,
    expires_at bigint NOT NULL,
    created_at bigint NOT NULL,
    last_consumed_at bigint NOT NULL,
    CONSTRAINT secret_permit_replay_state_check CHECK (((max_uses > 0) AND (consumed_uses > 0) AND (consumed_uses <= max_uses))),
    CONSTRAINT secret_permit_replay_state_check1 CHECK ((((replay_kind = 'SINGLE_USE'::text) AND (max_uses = 1)) OR ((replay_kind = 'BOUNDED_REUSE'::text) AND ((max_uses >= 2) AND (max_uses <= 16))))),
    CONSTRAINT secret_permit_replay_state_check2 CHECK (((expires_at > created_at) AND (last_consumed_at >= created_at))),
    CONSTRAINT secret_permit_replay_state_permit_id_check CHECK ((permit_id ~ '^(authority_[A-Za-z0-9_-]{20,128}|execution-assertion:[A-Za-z0-9._:/@-]{16,200})$'::text)),
    CONSTRAINT secret_permit_replay_state_replay_kind_check CHECK ((replay_kind = ANY (ARRAY['SINGLE_USE'::text, 'BOUNDED_REUSE'::text]))),
    CONSTRAINT secret_permit_replay_state_scope_digest_check CHECK ((scope_digest ~ '^sha256:[a-f0-9]{64}$'::text))
);

ALTER TABLE ONLY public.secret_permit_replay_state FORCE ROW LEVEL SECURITY;


--
-- Name: secret_preflight_journal; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_preflight_journal (
    preflight_id text NOT NULL,
    consumer_tenant_id text NOT NULL,
    target_definition_id text NOT NULL,
    target_revision bigint NOT NULL,
    target_owner_scope text NOT NULL,
    target_tenant_binding_id text,
    token_hash text NOT NULL,
    operation_state text NOT NULL,
    expires_at bigint NOT NULL,
    version bigint NOT NULL,
    checked_at bigint,
    actor_id text,
    response_credential_id text,
    response_binding_digest text,
    response_kek_id text,
    response_kek_version bigint,
    response_generation bigint,
    response_envelope_version bigint,
    response_ciphertext bytea,
    CONSTRAINT secret_preflight_journal_check CHECK ((((response_credential_id IS NULL) AND (response_binding_digest IS NULL) AND (response_kek_id IS NULL) AND (response_kek_version IS NULL) AND (response_generation IS NULL) AND (response_envelope_version IS NULL) AND (response_ciphertext IS NULL)) OR ((response_credential_id IS NOT NULL) AND (response_binding_digest ~ '^sha256:[a-f0-9]{64}$'::text) AND (response_kek_id IS NOT NULL) AND (response_kek_version > 0) AND (response_generation > 0) AND (response_envelope_version > 0) AND (octet_length(response_ciphertext) > 0) AND (checked_at IS NOT NULL) AND (actor_id IS NOT NULL)))),
    CONSTRAINT secret_preflight_journal_check1 CHECK ((((target_owner_scope = consumer_tenant_id) AND (target_tenant_binding_id IS NULL)) OR ((target_owner_scope = '__platform__'::text) AND (consumer_tenant_id <> '__platform__'::text) AND (target_tenant_binding_id IS NOT NULL)))),
    CONSTRAINT secret_preflight_journal_checked_at_check CHECK (((checked_at IS NULL) OR (checked_at > 0))),
    CONSTRAINT secret_preflight_journal_operation_state_check CHECK ((operation_state = ANY (ARRAY['REQUESTED'::text, 'PREFLIGHTING'::text, 'PREFLIGHTED'::text, 'RUNNING'::text, 'FENCED'::text, 'VALIDATING'::text, 'COMMITTING'::text, 'COMMITTED'::text, 'RETAINED'::text, 'ROLLING_BACK'::text, 'ROLLED_BACK'::text, 'PURGING'::text, 'PURGED'::text, 'FAILED'::text, 'CANCELLED'::text]))),
    CONSTRAINT secret_preflight_journal_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY public.secret_preflight_journal FORCE ROW LEVEL SECURITY;


--
-- Name: secret_provider_assignment; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_provider_assignment (
    assignment_id text NOT NULL,
    consumer_tenant_id text NOT NULL,
    assignment_role text NOT NULL,
    definition_id text NOT NULL,
    revision bigint NOT NULL,
    provider_owner_scope text NOT NULL,
    tenant_binding_id text,
    lifecycle_state text NOT NULL,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    CONSTRAINT secret_provider_assignment_assignment_role_check CHECK ((assignment_role = ANY (ARRAY['PLATFORM_STORAGE'::text, 'TENANT_SECRETS'::text]))),
    CONSTRAINT secret_provider_assignment_check CHECK ((((assignment_role = 'PLATFORM_STORAGE'::text) AND (consumer_tenant_id = '__platform__'::text) AND (provider_owner_scope = '__platform__'::text) AND (tenant_binding_id IS NULL)) OR ((assignment_role = 'TENANT_SECRETS'::text) AND (consumer_tenant_id <> '__platform__'::text) AND (((provider_owner_scope = consumer_tenant_id) AND (tenant_binding_id IS NULL)) OR ((provider_owner_scope = '__platform__'::text) AND (tenant_binding_id IS NOT NULL)))))),
    CONSTRAINT secret_provider_assignment_lifecycle_state_check CHECK ((lifecycle_state = ANY (ARRAY['CANDIDATE'::text, 'READY'::text, 'ACTIVE'::text, 'SUSPENDED'::text, 'RETAINED'::text, 'RETIRED'::text, 'PURGED'::text, 'FAILED'::text]))),
    CONSTRAINT secret_provider_assignment_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY public.secret_provider_assignment FORCE ROW LEVEL SECURITY;


--
-- Name: secret_provider_bootstrap_credential_material; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_provider_bootstrap_credential_material (
    definition_id text NOT NULL,
    revision bigint NOT NULL,
    credential_field text NOT NULL,
    material_credential_id text NOT NULL,
    material_generation bigint NOT NULL,
    CONSTRAINT secret_provider_bootstrap_credential__material_generation_check CHECK ((material_generation > 0))
);

ALTER TABLE ONLY public.secret_provider_bootstrap_credential_material FORCE ROW LEVEL SECURITY;


--
-- Name: secret_provider_cache_impact; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_provider_cache_impact (
    impact_id text NOT NULL,
    definition_id text NOT NULL,
    revision bigint NOT NULL,
    impact_kind text NOT NULL,
    binding_generation bigint,
    committed_at bigint NOT NULL,
    CONSTRAINT secret_provider_cache_impact_binding_generation_check CHECK (((binding_generation IS NULL) OR (binding_generation > 0))),
    CONSTRAINT secret_provider_cache_impact_impact_id_check CHECK ((impact_id ~ '^sci_[A-Za-z0-9_-]{20,128}$'::text)),
    CONSTRAINT secret_provider_cache_impact_impact_kind_check CHECK ((impact_kind = ANY (ARRAY['PROVIDER_REVISION'::text, 'CREDENTIAL_ROTATION'::text, 'RESOURCE_BINDING'::text, 'HEALTH_STATE'::text, 'RECOVERY'::text])))
);

ALTER TABLE ONLY public.secret_provider_cache_impact FORCE ROW LEVEL SECURITY;


--
-- Name: secret_provider_credential_binding; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_provider_credential_binding (
    definition_id text NOT NULL,
    revision bigint NOT NULL,
    credential_field text NOT NULL,
    storage_tier text NOT NULL,
    generation bigint NOT NULL,
    configured boolean NOT NULL,
    rotation_required boolean NOT NULL,
    version bigint NOT NULL,
    updated_at bigint NOT NULL,
    CONSTRAINT secret_provider_credential_binding_generation_check CHECK ((generation > 0)),
    CONSTRAINT secret_provider_credential_binding_storage_tier_check CHECK ((storage_tier = ANY (ARRAY['BOOTSTRAP'::text, 'PLATFORM'::text]))),
    CONSTRAINT secret_provider_credential_binding_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY public.secret_provider_credential_binding FORCE ROW LEVEL SECURITY;


--
-- Name: secret_provider_definition; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_provider_definition (
    definition_id text NOT NULL,
    owner_kind text NOT NULL,
    owner_scope text NOT NULL,
    role text NOT NULL,
    display_name text NOT NULL,
    lifecycle_state text NOT NULL,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    CONSTRAINT secret_provider_definition_check CHECK ((((owner_kind = 'PLATFORM'::text) AND (owner_scope = '__platform__'::text)) OR ((owner_kind = 'TENANT'::text) AND (owner_scope <> '__platform__'::text)))),
    CONSTRAINT secret_provider_definition_check1 CHECK ((((owner_kind = 'PLATFORM'::text) AND (role = ANY (ARRAY['PLATFORM_STORAGE'::text, 'PLATFORM_OFFERING'::text, 'DEPLOYMENT_SOURCE'::text]))) OR ((owner_kind = 'TENANT'::text) AND (role = 'TENANT_MANAGED'::text)))),
    CONSTRAINT secret_provider_definition_lifecycle_state_check CHECK ((lifecycle_state = ANY (ARRAY['CANDIDATE'::text, 'READY'::text, 'ACTIVE'::text, 'SUSPENDED'::text, 'RETAINED'::text, 'RETIRED'::text, 'PURGED'::text, 'FAILED'::text]))),
    CONSTRAINT secret_provider_definition_owner_kind_check CHECK ((owner_kind = ANY (ARRAY['PLATFORM'::text, 'TENANT'::text]))),
    CONSTRAINT secret_provider_definition_role_check CHECK ((role = ANY (ARRAY['PLATFORM_STORAGE'::text, 'PLATFORM_OFFERING'::text, 'TENANT_MANAGED'::text, 'DEPLOYMENT_SOURCE'::text]))),
    CONSTRAINT secret_provider_definition_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY public.secret_provider_definition FORCE ROW LEVEL SECURITY;


--
-- Name: secret_provider_environment_manifest_item; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_provider_environment_manifest_item (
    definition_id text NOT NULL,
    revision bigint NOT NULL,
    managed_secret_id text NOT NULL,
    CONSTRAINT secret_provider_environment_manifest_it_managed_secret_id_check CHECK ((managed_secret_id ~ '^sec_[A-Za-z0-9_-]{16,128}$'::text))
);

ALTER TABLE ONLY public.secret_provider_environment_manifest_item FORCE ROW LEVEL SECURITY;


--
-- Name: secret_provider_health; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_provider_health (
    definition_id text NOT NULL,
    revision bigint NOT NULL,
    health_state text NOT NULL,
    checked_at bigint NOT NULL,
    stale_after bigint NOT NULL,
    diagnostic_code text,
    version bigint NOT NULL,
    updated_at bigint NOT NULL,
    CONSTRAINT secret_provider_health_check CHECK (((checked_at >= 0) AND (stale_after >= checked_at) AND (version > 0))),
    CONSTRAINT secret_provider_health_diagnostic_code_check CHECK (((diagnostic_code IS NULL) OR (diagnostic_code ~ '^[A-Z0-9_]{1,96}$'::text))),
    CONSTRAINT secret_provider_health_health_state_check CHECK ((health_state = ANY (ARRAY['UNKNOWN'::text, 'HEALTHY'::text, 'STALE'::text, 'DEGRADED'::text, 'FAILED'::text])))
);

ALTER TABLE ONLY public.secret_provider_health FORCE ROW LEVEL SECURITY;


--
-- Name: secret_provider_kubernetes_mount_manifest_item; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_provider_kubernetes_mount_manifest_item (
    definition_id text NOT NULL,
    revision bigint NOT NULL,
    managed_secret_id text NOT NULL,
    CONSTRAINT secret_provider_kubernetes_mount_manife_managed_secret_id_check CHECK ((managed_secret_id ~ '^sec_[A-Za-z0-9_-]{16,128}$'::text))
);

ALTER TABLE ONLY public.secret_provider_kubernetes_mount_manifest_item FORCE ROW LEVEL SECURITY;


--
-- Name: secret_provider_platform_credential_material; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_provider_platform_credential_material (
    definition_id text NOT NULL,
    revision bigint NOT NULL,
    credential_field text NOT NULL,
    material_secret_id text NOT NULL,
    material_owner_tenant_id text NOT NULL,
    material_generation bigint NOT NULL,
    CONSTRAINT secret_provider_platform_credent_material_owner_tenant_id_check CHECK ((material_owner_tenant_id <> '__platform__'::text)),
    CONSTRAINT secret_provider_platform_credential_m_material_generation_check CHECK ((material_generation > 0))
);

ALTER TABLE ONLY public.secret_provider_platform_credential_material FORCE ROW LEVEL SECURITY;


--
-- Name: secret_provider_revision; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_provider_revision (
    definition_id text NOT NULL,
    revision bigint NOT NULL,
    owner_scope text NOT NULL,
    provider_type text NOT NULL,
    isolation_mode text NOT NULL,
    addressing_policy_id text NOT NULL,
    lifecycle_state text NOT NULL,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    ready_at bigint,
    CONSTRAINT secret_provider_revision_check CHECK (((provider_type <> ALL (ARRAY['KUBERNETES_MOUNT'::text, 'ENVIRONMENT'::text])) OR (isolation_mode = 'READ_ONLY_DEPLOYMENT'::text))),
    CONSTRAINT secret_provider_revision_isolation_mode_check CHECK ((isolation_mode = ANY (ARRAY['TENANT_KEY'::text, 'TENANT_POLICY'::text, 'TENANT_ROLE'::text, 'TENANT_NAMESPACE'::text, 'TENANT_VAULT'::text, 'READ_ONLY_DEPLOYMENT'::text]))),
    CONSTRAINT secret_provider_revision_lifecycle_state_check CHECK ((lifecycle_state = ANY (ARRAY['CANDIDATE'::text, 'READY'::text, 'ACTIVE'::text, 'SUSPENDED'::text, 'RETAINED'::text, 'RETIRED'::text, 'PURGED'::text, 'FAILED'::text]))),
    CONSTRAINT secret_provider_revision_provider_type_check CHECK ((provider_type = ANY (ARRAY['KMS'::text, 'VAULT'::text, 'AZURE_KEY_VAULT'::text, 'AWS_SECRETS_MANAGER'::text, 'KUBERNETES_MOUNT'::text, 'ENVIRONMENT'::text]))),
    CONSTRAINT secret_provider_revision_revision_check CHECK ((revision > 0)),
    CONSTRAINT secret_provider_revision_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY public.secret_provider_revision FORCE ROW LEVEL SECURITY;


--
-- Name: secret_provider_revision_aws; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_provider_revision_aws (
    definition_id text NOT NULL,
    revision bigint NOT NULL,
    region text NOT NULL,
    account_boundary text NOT NULL
);

ALTER TABLE ONLY public.secret_provider_revision_aws FORCE ROW LEVEL SECURITY;


--
-- Name: secret_provider_revision_azure; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_provider_revision_azure (
    definition_id text NOT NULL,
    revision bigint NOT NULL,
    vault_uri text NOT NULL,
    identity_boundary text NOT NULL,
    CONSTRAINT secret_provider_revision_azure_vault_uri_check CHECK ((vault_uri ~~ 'https://%'::text))
);

ALTER TABLE ONLY public.secret_provider_revision_azure FORCE ROW LEVEL SECURITY;


--
-- Name: secret_provider_revision_capability; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_provider_revision_capability (
    definition_id text NOT NULL,
    revision bigint NOT NULL,
    capability text NOT NULL,
    CONSTRAINT secret_provider_revision_capability_capability_check CHECK ((capability = ANY (ARRAY['READ'::text, 'WRITE'::text, 'DELETE'::text, 'VERSIONING'::text, 'CREDENTIAL_ROTATION'::text, 'BACKEND_TENANT_ISOLATION'::text])))
);

ALTER TABLE ONLY public.secret_provider_revision_capability FORCE ROW LEVEL SECURITY;


--
-- Name: secret_provider_revision_environment; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_provider_revision_environment (
    definition_id text NOT NULL,
    revision bigint NOT NULL,
    managed_secret_manifest_digest text NOT NULL,
    CONSTRAINT secret_provider_revision_env_managed_secret_manifest_dige_check CHECK ((managed_secret_manifest_digest ~~ 'sha256:%'::text))
);

ALTER TABLE ONLY public.secret_provider_revision_environment FORCE ROW LEVEL SECURITY;


--
-- Name: secret_provider_revision_kms; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_provider_revision_kms (
    definition_id text NOT NULL,
    revision bigint NOT NULL,
    key_purpose text NOT NULL,
    algorithm text NOT NULL,
    kms_provider_id text NOT NULL,
    kms_binding_key text NOT NULL,
    CONSTRAINT secret_provider_revision_kms_kms_provider_id_check CHECK ((kms_provider_id ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'::text))
);

ALTER TABLE ONLY public.secret_provider_revision_kms FORCE ROW LEVEL SECURITY;


--
-- Name: secret_provider_revision_kms_authority_credential_slot; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_provider_revision_kms_authority_credential_slot (
    definition_id text NOT NULL,
    revision bigint NOT NULL,
    credential_slot text NOT NULL,
    destination_digest text NOT NULL,
    CONSTRAINT secret_provider_revision_kms_authority_cr_credential_slot_check CHECK ((credential_slot ~ '^[a-z][a-z0-9-]{0,119}$'::text)),
    CONSTRAINT secret_provider_revision_kms_authority_destination_digest_check CHECK ((destination_digest ~ '^sha256:[a-f0-9]{64}$'::text))
);

ALTER TABLE ONLY public.secret_provider_revision_kms_authority_credential_slot FORCE ROW LEVEL SECURITY;


--
-- Name: secret_provider_revision_kms_authority_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_provider_revision_kms_authority_metadata (
    definition_id text NOT NULL,
    revision bigint NOT NULL,
    kms_provider_id text NOT NULL,
    profile_kind text NOT NULL,
    kms_destination_digest text NOT NULL,
    CONSTRAINT secret_provider_revision_kms_autho_kms_destination_digest_check CHECK ((kms_destination_digest ~ '^sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT secret_provider_revision_kms_authority_me_kms_provider_id_check CHECK ((kms_provider_id ~ '^[A-Za-z0-9][A-Za-z0-9._:@-]{0,159}$'::text)),
    CONSTRAINT secret_provider_revision_kms_authority_metad_profile_kind_check CHECK ((profile_kind = ANY (ARRAY['SOFTWARE'::text, 'AZURE_CLIENT_SECRET'::text, 'AZURE_PASSWORD'::text, 'AWS_LONG_LIVED'::text, 'AWS_SESSION'::text, 'VAULT'::text, 'DIGIDENTITY'::text])))
);

ALTER TABLE ONLY public.secret_provider_revision_kms_authority_metadata FORCE ROW LEVEL SECURITY;


--
-- Name: secret_provider_revision_kms_operation_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_provider_revision_kms_operation_metadata (
    definition_id text NOT NULL,
    revision bigint NOT NULL,
    provider_operation_type text NOT NULL,
    operation_locator text NOT NULL,
    operation_locator_digest text NOT NULL,
    operation_destination_digest text NOT NULL,
    credential_storage_provider_definition_id text,
    credential_storage_provider_revision bigint,
    software_keystore_password_credential_slot text,
    software_keystore_password_storage_destination_digest text,
    CONSTRAINT secret_provider_revision_kms_ope_operation_locator_digest_check CHECK ((operation_locator_digest ~ '^sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT secret_provider_revision_kms_oper_provider_operation_type_check CHECK ((provider_operation_type = ANY (ARRAY['SOFTWARE'::text, 'AZURE_CLIENT_SECRET'::text, 'AZURE_PASSWORD'::text, 'AWS_LONG_LIVED'::text, 'AWS_SESSION'::text, 'VAULT'::text, 'DIGIDENTITY'::text]))),
    CONSTRAINT secret_provider_revision_kms_operation__operation_locator_check CHECK (((operation_locator ~ '^[A-Za-z0-9][A-Za-z0-9._:@/-]*$'::text) AND ((length(operation_locator) >= 1) AND (length(operation_locator) <= 512)))),
    CONSTRAINT secret_provider_revision_kms_operation_destination_digest_check CHECK ((operation_destination_digest ~ '^sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT secret_provider_revision_kms_operation_metadata_check CHECK (((credential_storage_provider_definition_id IS NULL) = (credential_storage_provider_revision IS NULL))),
    CONSTRAINT secret_provider_revision_kms_operation_metadata_check1 CHECK (((credential_storage_provider_definition_id IS NOT NULL) AND (credential_storage_provider_revision IS NOT NULL))),
    CONSTRAINT secret_provider_revision_kms_operation_metadata_check2 CHECK ((((provider_operation_type = 'SOFTWARE'::text) AND (software_keystore_password_credential_slot ~ '^[a-z][a-z0-9-]{0,119}$'::text) AND (software_keystore_password_storage_destination_digest ~ '^sha256:[a-f0-9]{64}$'::text)) OR ((provider_operation_type <> 'SOFTWARE'::text) AND (software_keystore_password_credential_slot IS NULL) AND (software_keystore_password_storage_destination_digest IS NULL)))),
    CONSTRAINT secret_provider_revision_kms_operation_metadata_check3 CHECK (((credential_storage_provider_definition_id IS NULL) OR (credential_storage_provider_definition_id <> definition_id) OR (credential_storage_provider_revision <> revision)))
);

ALTER TABLE ONLY public.secret_provider_revision_kms_operation_metadata FORCE ROW LEVEL SECURITY;


--
-- Name: secret_provider_revision_kubernetes_mount; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_provider_revision_kubernetes_mount (
    definition_id text NOT NULL,
    revision bigint NOT NULL,
    managed_secret_manifest_digest text NOT NULL,
    CONSTRAINT secret_provider_revision_kub_managed_secret_manifest_dige_check CHECK ((managed_secret_manifest_digest ~~ 'sha256:%'::text))
);

ALTER TABLE ONLY public.secret_provider_revision_kubernetes_mount FORCE ROW LEVEL SECURITY;


--
-- Name: secret_provider_revision_transition; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_provider_revision_transition (
    definition_id text NOT NULL,
    revision bigint NOT NULL,
    tested_at bigint,
    latest_preflight_id text,
    observed_outcome text,
    observed_at bigint,
    observed_failure_code text,
    observed_fence bigint DEFAULT 0 NOT NULL,
    CONSTRAINT secret_provider_revision_transition_check CHECK (((observed_outcome IS NULL) = (observed_at IS NULL))),
    CONSTRAINT secret_provider_revision_transition_check1 CHECK (((observed_failure_code IS NULL) OR (observed_outcome = 'FAILED'::text))),
    CONSTRAINT secret_provider_revision_transition_observed_at_check CHECK (((observed_at IS NULL) OR (observed_at >= 0))),
    CONSTRAINT secret_provider_revision_transition_observed_failure_code_check CHECK (((observed_failure_code IS NULL) OR (observed_failure_code ~ '^[A-Z][A-Z0-9_]{0,63}$'::text))),
    CONSTRAINT secret_provider_revision_transition_observed_fence_check CHECK ((observed_fence >= 0)),
    CONSTRAINT secret_provider_revision_transition_observed_outcome_check CHECK (((observed_outcome IS NULL) OR (observed_outcome = ANY (ARRAY['PASSED'::text, 'FAILED'::text])))),
    CONSTRAINT secret_provider_revision_transition_tested_at_check CHECK (((tested_at IS NULL) OR (tested_at >= 0)))
);

ALTER TABLE ONLY public.secret_provider_revision_transition FORCE ROW LEVEL SECURITY;


--
-- Name: secret_provider_revision_vault; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_provider_revision_vault (
    definition_id text NOT NULL,
    revision bigint NOT NULL,
    endpoint_uri text NOT NULL,
    namespace_policy text NOT NULL,
    CONSTRAINT secret_provider_revision_vault_endpoint_uri_check CHECK ((endpoint_uri ~~ 'https://%'::text))
);

ALTER TABLE ONLY public.secret_provider_revision_vault FORCE ROW LEVEL SECURITY;


--
-- Name: secret_purge_journal; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_purge_journal (
    purge_id text NOT NULL,
    retention_id text NOT NULL,
    operation_state text NOT NULL,
    fence bigint NOT NULL,
    idempotency_key_hash text NOT NULL,
    version bigint NOT NULL,
    CONSTRAINT secret_purge_journal_fence_check CHECK ((fence >= 0)),
    CONSTRAINT secret_purge_journal_operation_state_check CHECK ((operation_state = ANY (ARRAY['REQUESTED'::text, 'PREFLIGHTING'::text, 'PREFLIGHTED'::text, 'RUNNING'::text, 'FENCED'::text, 'VALIDATING'::text, 'COMMITTING'::text, 'COMMITTED'::text, 'RETAINED'::text, 'ROLLING_BACK'::text, 'ROLLED_BACK'::text, 'PURGING'::text, 'PURGED'::text, 'FAILED'::text, 'CANCELLED'::text]))),
    CONSTRAINT secret_purge_journal_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY public.secret_purge_journal FORCE ROW LEVEL SECURITY;


--
-- Name: secret_record; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_record (
    secret_id text NOT NULL,
    owner_tenant_id text NOT NULL,
    storage_consumer_tenant_id text NOT NULL,
    record_class text NOT NULL,
    purpose text NOT NULL,
    generation bigint NOT NULL,
    lifecycle_state text NOT NULL,
    assignment_id text NOT NULL,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    CONSTRAINT secret_record_check CHECK ((((record_class = 'TENANT_VALUE'::text) AND (purpose ~ '^[a-z][a-z0-9-]{0,119}$'::text) AND (purpose <> 'internal'::text) AND (purpose !~~ 'internal-%'::text) AND (purpose <> 'oid4vci-issuer-trust-domain-api-client-secret'::text)) OR ((record_class = 'SYSTEM_CREDENTIAL'::text) AND (purpose ~ '^[a-z][a-z0-9-]{0,119}$'::text) AND ((purpose = 'internal'::text) OR (purpose ~~ 'internal-%'::text) OR (purpose = 'oid4vci-issuer-trust-domain-api-client-secret'::text))) OR (record_class = ANY (ARRAY['PROVIDER_CREDENTIAL'::text, 'TENANT_CAPABILITY'::text])))),
    CONSTRAINT secret_record_check1 CHECK ((((record_class = 'TENANT_VALUE'::text) AND (storage_consumer_tenant_id = owner_tenant_id)) OR ((record_class = ANY (ARRAY['PROVIDER_CREDENTIAL'::text, 'TENANT_CAPABILITY'::text, 'SYSTEM_CREDENTIAL'::text])) AND (owner_tenant_id <> '__platform__'::text) AND (storage_consumer_tenant_id = '__platform__'::text)))),
    CONSTRAINT secret_record_generation_check CHECK ((generation > 0)),
    CONSTRAINT secret_record_lifecycle_state_check CHECK ((lifecycle_state = ANY (ARRAY['CANDIDATE'::text, 'READY'::text, 'ACTIVE'::text, 'SUSPENDED'::text, 'RETAINED'::text, 'RETIRED'::text, 'PURGED'::text, 'FAILED'::text]))),
    CONSTRAINT secret_record_record_class_check CHECK ((record_class = ANY (ARRAY['TENANT_VALUE'::text, 'PROVIDER_CREDENTIAL'::text, 'TENANT_CAPABILITY'::text, 'SYSTEM_CREDENTIAL'::text]))),
    CONSTRAINT secret_record_secret_id_check CHECK ((secret_id ~ '^sec_[A-Za-z0-9_-]{16,128}$'::text)),
    CONSTRAINT secret_record_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY public.secret_record FORCE ROW LEVEL SECURITY;


--
-- Name: secret_record_generation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_record_generation (
    secret_id text NOT NULL,
    owner_tenant_id text NOT NULL,
    generation bigint NOT NULL,
    storage_consumer_tenant_id text NOT NULL,
    record_class text NOT NULL,
    created_at bigint NOT NULL,
    CONSTRAINT secret_record_generation_generation_check CHECK ((generation > 0)),
    CONSTRAINT secret_record_generation_record_class_check CHECK ((record_class = ANY (ARRAY['TENANT_VALUE'::text, 'PROVIDER_CREDENTIAL'::text, 'TENANT_CAPABILITY'::text, 'SYSTEM_CREDENTIAL'::text])))
);

ALTER TABLE ONLY public.secret_record_generation FORCE ROW LEVEL SECURITY;


--
-- Name: secret_resource_credential_binding; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_resource_credential_binding (
    owner_tenant_id text NOT NULL,
    resource_kind text NOT NULL,
    resource_instance_key text NOT NULL,
    credential_slot text NOT NULL,
    binding_generation bigint NOT NULL,
    secret_id text NOT NULL,
    secret_generation bigint NOT NULL,
    record_class text NOT NULL,
    provider_definition_id text NOT NULL,
    provider_revision bigint NOT NULL,
    tenant_binding_id text,
    provider_assignment_id text,
    lifecycle_state text NOT NULL,
    created_at bigint NOT NULL,
    retired_at bigint,
    CONSTRAINT secret_resource_credential_binding_check CHECK (((binding_generation > 0) AND (secret_generation > 0) AND (provider_revision > 0))),
    CONSTRAINT secret_resource_credential_binding_check1 CHECK ((((record_class = 'TENANT_VALUE'::text) AND (provider_assignment_id IS NOT NULL)) OR ((record_class <> 'TENANT_VALUE'::text) AND (provider_assignment_id IS NULL)))),
    CONSTRAINT secret_resource_credential_binding_check2 CHECK ((((lifecycle_state = 'ACTIVE'::text) AND (retired_at IS NULL)) OR ((lifecycle_state <> 'ACTIVE'::text) AND (retired_at IS NOT NULL)))),
    CONSTRAINT secret_resource_credential_binding_credential_slot_check CHECK ((credential_slot ~ '^[a-z][a-z0-9-]{0,119}$'::text)),
    CONSTRAINT secret_resource_credential_binding_lifecycle_state_check CHECK ((lifecycle_state = ANY (ARRAY['ACTIVE'::text, 'DETACHED'::text, 'RETIRED'::text, 'FAILED'::text]))),
    CONSTRAINT secret_resource_credential_binding_owner_tenant_id_check CHECK ((owner_tenant_id <> '__platform__'::text)),
    CONSTRAINT secret_resource_credential_binding_record_class_check CHECK ((record_class = ANY (ARRAY['TENANT_VALUE'::text, 'SYSTEM_CREDENTIAL'::text, 'PROVIDER_CREDENTIAL'::text, 'TENANT_CAPABILITY'::text]))),
    CONSTRAINT secret_resource_credential_binding_resource_instance_key_check CHECK (((length(resource_instance_key) >= 1) AND (length(resource_instance_key) <= 256))),
    CONSTRAINT secret_resource_credential_binding_resource_kind_check CHECK ((resource_kind ~ '^[a-z][a-z0-9-]{0,119}$'::text))
);

ALTER TABLE ONLY public.secret_resource_credential_binding FORCE ROW LEVEL SECURITY;


--
-- Name: secret_retention_journal; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_retention_journal (
    retention_id text NOT NULL,
    migration_id text NOT NULL,
    retain_until bigint NOT NULL,
    operation_state text NOT NULL,
    fence bigint NOT NULL,
    version bigint NOT NULL,
    CONSTRAINT secret_retention_journal_fence_check CHECK ((fence >= 0)),
    CONSTRAINT secret_retention_journal_operation_state_check CHECK ((operation_state = ANY (ARRAY['REQUESTED'::text, 'PREFLIGHTING'::text, 'PREFLIGHTED'::text, 'RUNNING'::text, 'FENCED'::text, 'VALIDATING'::text, 'COMMITTING'::text, 'COMMITTED'::text, 'RETAINED'::text, 'ROLLING_BACK'::text, 'ROLLED_BACK'::text, 'PURGING'::text, 'PURGED'::text, 'FAILED'::text, 'CANCELLED'::text]))),
    CONSTRAINT secret_retention_journal_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY public.secret_retention_journal FORCE ROW LEVEL SECURITY;


--
-- Name: secret_server_kms_resource_binding; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_server_kms_resource_binding (
    owner_tenant_id text NOT NULL,
    product_offering_key text NOT NULL,
    resource_instance_key text NOT NULL,
    public_handle text NOT NULL,
    provider_definition_id text NOT NULL,
    provider_revision bigint NOT NULL,
    lifecycle_state text NOT NULL,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    CONSTRAINT secret_server_kms_resource_binding_lifecycle_state_check CHECK ((lifecycle_state = ANY (ARRAY['ACTIVE'::text, 'RETIRED'::text, 'FAILED'::text]))),
    CONSTRAINT secret_server_kms_resource_binding_owner_tenant_id_check CHECK ((owner_tenant_id <> '__platform__'::text)),
    CONSTRAINT secret_server_kms_resource_binding_provider_revision_check CHECK ((provider_revision > 0)),
    CONSTRAINT secret_server_kms_resource_binding_public_handle_check CHECK ((public_handle ~ '^krh_[A-Za-z0-9_-]{20,128}$'::text)),
    CONSTRAINT secret_server_kms_resource_binding_resource_instance_key_check CHECK (((length(resource_instance_key) >= 1) AND (length(resource_instance_key) <= 256))),
    CONSTRAINT secret_server_kms_resource_binding_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY public.secret_server_kms_resource_binding FORCE ROW LEVEL SECURITY;


--
-- Name: secret_server_kms_resource_offering; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_server_kms_resource_offering (
    product_offering_key text NOT NULL,
    resource_kind text NOT NULL,
    offering_scope text NOT NULL,
    visibility text NOT NULL,
    default_selected bigint NOT NULL,
    provider_definition_id text NOT NULL,
    provider_revision bigint NOT NULL,
    storage_provider_definition_id text NOT NULL,
    storage_provider_revision bigint NOT NULL,
    permitted_operation_type text NOT NULL,
    logical_provider_strategy text NOT NULL,
    lifecycle_state text NOT NULL,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    CONSTRAINT secret_server_kms_resource_offe_logical_provider_strategy_check CHECK ((logical_provider_strategy = ANY (ARRAY['INTERNAL_BOOTSTRAP_STORAGE'::text, 'PRODUCT_MANAGED_NON_DEFAULT'::text]))),
    CONSTRAINT secret_server_kms_resource_offer_permitted_operation_type_check CHECK ((permitted_operation_type = ANY (ARRAY['SOFTWARE'::text, 'AZURE_CLIENT_SECRET'::text, 'AZURE_PASSWORD'::text, 'AWS_LONG_LIVED'::text, 'AWS_SESSION'::text]))),
    CONSTRAINT secret_server_kms_resource_offering_check CHECK (((provider_revision > 0) AND (storage_provider_revision > 0) AND (version > 0))),
    CONSTRAINT secret_server_kms_resource_offering_check1 CHECK (((resource_kind = 'INTERNAL_SOFTWARE_KMS'::text) OR (provider_definition_id <> storage_provider_definition_id) OR (provider_revision <> storage_provider_revision))),
    CONSTRAINT secret_server_kms_resource_offering_check2 CHECK ((((resource_kind = 'INTERNAL_SOFTWARE_KMS'::text) AND (offering_scope = 'SERVER_INTERNAL'::text) AND (visibility = 'HIDDEN'::text) AND (default_selected = 0) AND (logical_provider_strategy = 'INTERNAL_BOOTSTRAP_STORAGE'::text)) OR ((resource_kind = ANY (ARRAY['SOFTWARE'::text, 'AZURE_KEY_VAULT'::text, 'AWS_KMS'::text])) AND (offering_scope = 'TENANT_TYPED'::text) AND (visibility = 'TENANT_VISIBLE'::text) AND (logical_provider_strategy = 'PRODUCT_MANAGED_NON_DEFAULT'::text)))),
    CONSTRAINT secret_server_kms_resource_offering_check3 CHECK (((resource_kind = 'SOFTWARE'::text) OR (default_selected = 0))),
    CONSTRAINT secret_server_kms_resource_offering_default_selected_check CHECK ((default_selected = ANY (ARRAY[(0)::bigint, (1)::bigint]))),
    CONSTRAINT secret_server_kms_resource_offering_lifecycle_state_check CHECK ((lifecycle_state = ANY (ARRAY['ACTIVE'::text, 'RETIRED'::text, 'FAILED'::text]))),
    CONSTRAINT secret_server_kms_resource_offering_offering_scope_check CHECK ((offering_scope = ANY (ARRAY['SERVER_INTERNAL'::text, 'TENANT_TYPED'::text]))),
    CONSTRAINT secret_server_kms_resource_offering_product_offering_key_check CHECK ((product_offering_key ~ '^kms-[a-z0-9-]{3,120}$'::text)),
    CONSTRAINT secret_server_kms_resource_offering_resource_kind_check CHECK ((resource_kind = ANY (ARRAY['INTERNAL_SOFTWARE_KMS'::text, 'SOFTWARE'::text, 'AZURE_KEY_VAULT'::text, 'AWS_KMS'::text]))),
    CONSTRAINT secret_server_kms_resource_offering_visibility_check CHECK ((visibility = ANY (ARRAY['HIDDEN'::text, 'TENANT_VISIBLE'::text])))
);

ALTER TABLE ONLY public.secret_server_kms_resource_offering FORCE ROW LEVEL SECURITY;


--
-- Name: secret_tenant_kms_default_provider; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_tenant_kms_default_provider (
    tenant_id text NOT NULL,
    provider_id text NOT NULL,
    updated_at bigint NOT NULL,
    CONSTRAINT secret_tenant_kms_default_provider_provider_id_check CHECK ((provider_id ~ '^[a-z][a-z0-9-]{2,63}$'::text)),
    CONSTRAINT secret_tenant_kms_default_provider_tenant_id_check CHECK (((length(tenant_id) >= 1) AND (length(tenant_id) <= 160)))
);

ALTER TABLE ONLY public.secret_tenant_kms_default_provider FORCE ROW LEVEL SECURITY;


--
-- Name: secret_tenant_kms_enabled_provider; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_tenant_kms_enabled_provider (
    tenant_id text NOT NULL,
    provider_id text NOT NULL,
    created_at bigint NOT NULL,
    CONSTRAINT secret_tenant_kms_enabled_provider_provider_id_check CHECK ((provider_id ~ '^[a-z][a-z0-9-]{2,63}$'::text)),
    CONSTRAINT secret_tenant_kms_enabled_provider_tenant_id_check CHECK (((length(tenant_id) >= 1) AND (length(tenant_id) <= 160)))
);

ALTER TABLE ONLY public.secret_tenant_kms_enabled_provider FORCE ROW LEVEL SECURITY;


--
-- Name: secret_transition_bootstrap_material_receipt; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_transition_bootstrap_material_receipt (
    operation_id text NOT NULL,
    slot_id text NOT NULL,
    aad_digest text NOT NULL,
    generation bigint NOT NULL,
    fence bigint NOT NULL,
    credential_id text NOT NULL,
    purpose text NOT NULL,
    kek_id text NOT NULL,
    kek_version bigint NOT NULL,
    envelope_version bigint NOT NULL,
    encrypted_envelope bytea NOT NULL,
    CONSTRAINT secret_transition_bootstrap_material_r_encrypted_envelope_check CHECK ((octet_length(encrypted_envelope) > 0)),
    CONSTRAINT secret_transition_bootstrap_material_receipt_aad_digest_check CHECK ((aad_digest ~ '^sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT secret_transition_bootstrap_material_receipt_check CHECK (((generation > 0) AND (fence > 0) AND (kek_version > 0) AND (envelope_version > 0))),
    CONSTRAINT secret_transition_bootstrap_material_receipt_purpose_check CHECK ((purpose = ANY (ARRAY['PLATFORM_STORAGE'::text, 'OFFERING_PROVISIONER'::text])))
);

ALTER TABLE ONLY public.secret_transition_bootstrap_material_receipt FORCE ROW LEVEL SECURITY;


--
-- Name: secret_transition_idempotency; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_transition_idempotency (
    scope_kind text NOT NULL,
    scope_id text NOT NULL,
    operation_kind text NOT NULL,
    idempotency_key_mac text NOT NULL,
    canonical_request_mac text NOT NULL,
    transition_id text NOT NULL,
    result_definition_id text,
    result_revision bigint,
    actor_id text NOT NULL,
    correlation_id text NOT NULL,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    CONSTRAINT secret_transition_idempotency_actor_id_check CHECK (((length(actor_id) >= 1) AND (length(actor_id) <= 256))),
    CONSTRAINT secret_transition_idempotency_canonical_request_mac_check CHECK ((canonical_request_mac ~ '^hmac-sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT secret_transition_idempotency_check CHECK ((((scope_kind = ANY (ARRAY['PLATFORM_STORAGE'::text, 'PLATFORM_OFFERING'::text, 'DEPLOYMENT_SOURCE'::text])) AND (scope_id = '__platform__'::text)) OR ((scope_kind = 'TENANT_MANAGED'::text) AND (scope_id <> '__platform__'::text)))),
    CONSTRAINT secret_transition_idempotency_check1 CHECK (((result_definition_id IS NULL) = (result_revision IS NULL))),
    CONSTRAINT secret_transition_idempotency_correlation_id_check CHECK (((length(correlation_id) >= 1) AND (length(correlation_id) <= 256))),
    CONSTRAINT secret_transition_idempotency_idempotency_key_mac_check CHECK ((idempotency_key_mac ~ '^hmac-sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT secret_transition_idempotency_operation_kind_check CHECK ((operation_kind = ANY (ARRAY['PROVIDER_CREATE'::text, 'PROVIDER_REVISION_CREATE'::text, 'PROVIDER_TEST'::text, 'PROVIDER_PREFLIGHT'::text, 'PROVIDER_READY'::text, 'PROVIDER_CREDENTIAL_STAGE'::text, 'PROVIDER_CREDENTIAL_ROTATE'::text, 'OFFERING_PUBLISH'::text, 'OFFERING_PREFLIGHT'::text, 'TENANT_ASSIGNMENT_INITIALIZE'::text, 'MIGRATION_START'::text, 'MIGRATION_RESUME'::text, 'MIGRATION_ROLLBACK'::text, 'MIGRATION_PURGE'::text]))),
    CONSTRAINT secret_transition_idempotency_result_revision_check CHECK (((result_revision IS NULL) OR (result_revision > 0))),
    CONSTRAINT secret_transition_idempotency_scope_kind_check CHECK ((scope_kind = ANY (ARRAY['PLATFORM_STORAGE'::text, 'PLATFORM_OFFERING'::text, 'DEPLOYMENT_SOURCE'::text, 'TENANT_MANAGED'::text]))),
    CONSTRAINT secret_transition_idempotency_transition_id_check CHECK ((transition_id ~ '^(trn|smg)_[A-Za-z0-9_-]{20,128}$'::text)),
    CONSTRAINT secret_transition_idempotency_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY public.secret_transition_idempotency FORCE ROW LEVEL SECURITY;


--
-- Name: secret_transition_material_slot; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_transition_material_slot (
    operation_id text NOT NULL,
    slot_id text NOT NULL,
    field_name text NOT NULL,
    material_tier text NOT NULL,
    material_purpose text NOT NULL,
    owner_tenant_id text,
    definition_id text NOT NULL,
    revision bigint NOT NULL,
    tenant_binding_id text,
    generation bigint NOT NULL,
    bootstrap_purpose text,
    fence bigint NOT NULL,
    lifecycle_state text NOT NULL,
    CONSTRAINT secret_transition_material_slot_check CHECK ((((material_tier = 'PLATFORM_BOOTSTRAP'::text) AND (bootstrap_purpose = ANY (ARRAY['PLATFORM_STORAGE'::text, 'OFFERING_PROVISIONER'::text]))) OR ((material_tier = 'PLATFORM_STORAGE'::text) AND (bootstrap_purpose IS NULL)))),
    CONSTRAINT secret_transition_material_slot_check1 CHECK (((material_purpose = 'PROVIDER_CREDENTIAL'::text) OR ((owner_tenant_id IS NOT NULL) AND (tenant_binding_id IS NOT NULL)))),
    CONSTRAINT secret_transition_material_slot_fence_check CHECK ((fence > 0)),
    CONSTRAINT secret_transition_material_slot_field_name_check CHECK ((field_name ~ '^[A-Za-z][A-Za-z0-9._-]{0,127}$'::text)),
    CONSTRAINT secret_transition_material_slot_generation_check CHECK ((generation > 0)),
    CONSTRAINT secret_transition_material_slot_lifecycle_state_check CHECK ((lifecycle_state = ANY (ARRAY['CANDIDATE'::text, 'ACTIVE'::text, 'RETIRED'::text, 'PURGED'::text, 'FAILED'::text]))),
    CONSTRAINT secret_transition_material_slot_material_purpose_check CHECK ((material_purpose = ANY (ARRAY['PROVIDER_CREDENTIAL'::text, 'TENANT_CAPABILITY'::text, 'OFFERING_PROVISIONING_SEED'::text]))),
    CONSTRAINT secret_transition_material_slot_material_tier_check CHECK ((material_tier = ANY (ARRAY['PLATFORM_BOOTSTRAP'::text, 'PLATFORM_STORAGE'::text])))
);

ALTER TABLE ONLY public.secret_transition_material_slot FORCE ROW LEVEL SECURITY;


--
-- Name: secret_transition_platform_material_receipt; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_transition_platform_material_receipt (
    operation_id text NOT NULL,
    slot_id text NOT NULL,
    aad_digest text NOT NULL,
    generation bigint NOT NULL,
    fence bigint NOT NULL,
    secret_record_id text NOT NULL,
    owner_tenant_id text NOT NULL,
    CONSTRAINT secret_transition_platform_material_receipt_aad_digest_check CHECK ((aad_digest ~ '^sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT secret_transition_platform_material_receipt_check CHECK (((generation > 0) AND (fence > 0)))
);

ALTER TABLE ONLY public.secret_transition_platform_material_receipt FORCE ROW LEVEL SECURITY;


--
-- Name: secret_value_mutation_fence_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.secret_value_mutation_fence_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: secret_value_mutation_journal; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secret_value_mutation_journal (
    operation_id text NOT NULL,
    consumer_tenant_id text NOT NULL,
    secret_id text NOT NULL,
    source_assignment_id text NOT NULL,
    actor_id text NOT NULL,
    original_platform_actor_id text,
    delegated_capability_id text,
    delegated_capability_generation bigint,
    mutation_kind text NOT NULL,
    mutation_phase text NOT NULL,
    target_generation bigint NOT NULL,
    idempotency_key_mac text NOT NULL,
    canonical_request_mac text NOT NULL,
    fence bigint NOT NULL,
    expected_record_version bigint NOT NULL,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    CONSTRAINT secret_value_mutation_journal_canonical_request_mac_check CHECK ((canonical_request_mac ~ '^hmac-sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT secret_value_mutation_journal_check CHECK ((((delegated_capability_id IS NULL) AND (delegated_capability_generation IS NULL)) OR ((delegated_capability_id IS NOT NULL) AND (delegated_capability_generation > 0)))),
    CONSTRAINT secret_value_mutation_journal_expected_record_version_check CHECK ((expected_record_version > 0)),
    CONSTRAINT secret_value_mutation_journal_fence_check CHECK ((fence > 0)),
    CONSTRAINT secret_value_mutation_journal_idempotency_key_mac_check CHECK ((idempotency_key_mac ~ '^hmac-sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT secret_value_mutation_journal_mutation_kind_check CHECK ((mutation_kind = ANY (ARRAY['CREATE'::text, 'ROTATE'::text, 'PURGE'::text]))),
    CONSTRAINT secret_value_mutation_journal_mutation_phase_check CHECK ((mutation_phase = ANY (ARRAY['PREPARED'::text, 'TARGET_ABSENCE_VERIFIED'::text, 'PROVIDER_WRITTEN'::text, 'PROVIDER_VERIFIED'::text, 'COMMITTED'::text, 'PURGED'::text, 'FAILED'::text]))),
    CONSTRAINT secret_value_mutation_journal_operation_id_check CHECK ((operation_id ~ '^svm_[A-Za-z0-9_-]{20,128}$'::text)),
    CONSTRAINT secret_value_mutation_journal_target_generation_check CHECK ((target_generation > 0)),
    CONSTRAINT secret_value_mutation_journal_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY public.secret_value_mutation_journal FORCE ROW LEVEL SECURITY;


--
-- Name: server_party; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.server_party (
    party_id text NOT NULL,
    management_mode text NOT NULL,
    runtime_mode text,
    operator_party_id text,
    service_tier text,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: service; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.service (
    party_id text NOT NULL,
    tenant_id text NOT NULL,
    service_type text,
    endpoint_uri text,
    oauth_client_id text,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: service_instance_quota_lock; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.service_instance_quota_lock (
    tenant_id text NOT NULL,
    service_type text NOT NULL,
    version integer NOT NULL
);


--
-- Name: service_instance_quota_reservation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.service_instance_quota_reservation (
    id text NOT NULL,
    tenant_id text NOT NULL,
    service_type text NOT NULL,
    subject_id text NOT NULL,
    operation_id text NOT NULL,
    status text NOT NULL,
    created_epoch_ms bigint NOT NULL,
    expires_epoch_ms bigint NOT NULL,
    completed_epoch_ms bigint
);


--
-- Name: session; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.session (
    id text NOT NULL,
    tenant_id text NOT NULL,
    session_type text NOT NULL,
    session_key text NOT NULL,
    status text NOT NULL,
    session_data text,
    expires_at timestamp with time zone,
    created_by_id text,
    created_at timestamp with time zone NOT NULL,
    updated_by_id text,
    updated_at timestamp with time zone NOT NULL,
    deleted_by_id text,
    deleted_at timestamp with time zone
);


--
-- Name: single_use_object; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.single_use_object (
    namespace text NOT NULL,
    key text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    recorded_at timestamp with time zone NOT NULL
);


--
-- Name: software_assignment; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.software_assignment (
    id text NOT NULL,
    tenant_id text NOT NULL,
    software_party_id text NOT NULL,
    assignee_party_id text NOT NULL,
    assignee_type text NOT NULL,
    assignment_status text NOT NULL,
    settings_profile_ref text,
    policy_profile_ref text,
    onboarding_token_ref text,
    onboarded_at timestamp with time zone,
    valid_from timestamp with time zone NOT NULL,
    valid_until timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: software_capability; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.software_capability (
    id text NOT NULL,
    tenant_id text NOT NULL,
    party_id text NOT NULL,
    capability_type text NOT NULL,
    is_enabled boolean DEFAULT true NOT NULL,
    system boolean DEFAULT false NOT NULL,
    lifecycle_status text DEFAULT 'PROVISIONING'::text NOT NULL,
    lifecycle_status_reason text,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: software_capability_binding; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.software_capability_binding (
    id text NOT NULL,
    tenant_id text NOT NULL,
    source_party_id text NOT NULL,
    source_capability_type text NOT NULL,
    target_party_id text NOT NULL,
    target_capability_type text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    display_order integer DEFAULT 0 NOT NULL,
    config_json text,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: software_config_binding; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.software_config_binding (
    id text NOT NULL,
    tenant_id text NOT NULL,
    software_party_id text NOT NULL,
    capability_id text,
    deployment_id text,
    app_id text NOT NULL,
    app_version text,
    profile text DEFAULT 'default'::text NOT NULL,
    service_id text,
    config_scope text NOT NULL,
    config_scope_identifier text,
    config_key_prefix text NOT NULL,
    binding_type text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: software_credential; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.software_credential (
    id text NOT NULL,
    tenant_id text NOT NULL,
    software_party_id text NOT NULL,
    capability_id text,
    credential_type text NOT NULL,
    label text,
    client_id text,
    secret_id text,
    key_alias text,
    metadata jsonb,
    is_active boolean DEFAULT true NOT NULL,
    valid_from timestamp with time zone NOT NULL,
    valid_until timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    CONSTRAINT software_credential_secret_id_check CHECK (((secret_id IS NULL) OR (secret_id ~ '^sec_[A-Za-z0-9_-]{16,128}$'::text)))
);


--
-- Name: software_deployment; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.software_deployment (
    id text NOT NULL,
    tenant_id text NOT NULL,
    software_party_id text NOT NULL,
    capability_id text,
    deployment_type text NOT NULL,
    environment text,
    region text,
    runtime_ref text,
    orchestrator_ref text,
    deployment_status text DEFAULT 'PENDING'::text NOT NULL,
    lifecycle_status_reason text,
    last_sync_at timestamp with time zone,
    last_health_check_at timestamp with time zone,
    last_health_status text,
    last_error text,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: software_endpoint; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.software_endpoint (
    id text NOT NULL,
    tenant_id text NOT NULL,
    software_party_id text NOT NULL,
    capability_id text,
    deployment_id text,
    endpoint_type text NOT NULL,
    url text NOT NULL,
    is_primary boolean DEFAULT false NOT NULL,
    source text DEFAULT 'DECLARED'::text NOT NULL,
    last_verified_at timestamp with time zone,
    status text DEFAULT 'ACTIVE'::text NOT NULL,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text
);


--
-- Name: software_party; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.software_party (
    party_id text NOT NULL,
    tenant_id text NOT NULL,
    software_kind text NOT NULL,
    display_version text,
    vendor_party_id text,
    software_family text,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: subscription; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscription (
    id text NOT NULL,
    tenant_id text NOT NULL,
    party_id text NOT NULL,
    plan_ref text,
    status text DEFAULT 'ACTIVE'::text NOT NULL,
    valid_from timestamp with time zone,
    valid_to timestamp with time zone,
    billing_ref text,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: subscription_command_override; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscription_command_override (
    subscription_id text NOT NULL,
    command_pattern text NOT NULL,
    effect text NOT NULL
);


--
-- Name: subscription_feature; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscription_feature (
    subscription_id text NOT NULL,
    feature_key text NOT NULL,
    value_type text NOT NULL,
    value_text text,
    window_spec text
);


--
-- Name: subscription_quota; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscription_quota (
    subscription_id text NOT NULL,
    quota_key text NOT NULL,
    max_value bigint NOT NULL,
    kind text NOT NULL,
    window_spec text,
    consume_on text DEFAULT 'SUCCESS'::text NOT NULL
);


--
-- Name: system_credential_reference; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.system_credential_reference (
    owner_tenant_id text NOT NULL,
    workload_actor_id text NOT NULL,
    purpose text NOT NULL,
    secret_id text NOT NULL,
    record_class text DEFAULT 'SYSTEM_CREDENTIAL'::text NOT NULL,
    generation bigint NOT NULL,
    lifecycle_state text NOT NULL,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    CONSTRAINT system_credential_reference_check CHECK (((generation > 0) AND (version > 0))),
    CONSTRAINT system_credential_reference_lifecycle_state_check CHECK ((lifecycle_state = ANY (ARRAY['CANDIDATE'::text, 'ACTIVE'::text, 'RETIRED'::text, 'FAILED'::text]))),
    CONSTRAINT system_credential_reference_owner_tenant_id_check CHECK ((owner_tenant_id <> '__platform__'::text)),
    CONSTRAINT system_credential_reference_purpose_check CHECK (((purpose ~ '^[a-z][a-z0-9-]{0,119}$'::text) AND ((purpose = 'internal'::text) OR (purpose ~~ 'internal-%'::text) OR (purpose = 'oid4vci-issuer-trust-domain-api-client-secret'::text)))),
    CONSTRAINT system_credential_reference_record_class_check CHECK ((record_class = 'SYSTEM_CREDENTIAL'::text)),
    CONSTRAINT system_credential_reference_workload_actor_id_check CHECK ((((length(workload_actor_id) >= 1) AND (length(workload_actor_id) <= 256)) AND (workload_actor_id !~~ '%*%'::text)))
);

ALTER TABLE ONLY public.system_credential_reference FORCE ROW LEVEL SECURITY;


--
-- Name: system_credential_transition; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.system_credential_transition (
    operation_id text NOT NULL,
    owner_tenant_id text NOT NULL,
    target_tenant_id text NOT NULL,
    workload_actor_id text NOT NULL,
    purpose text NOT NULL,
    secret_id text NOT NULL,
    operation_kind text NOT NULL,
    operation_phase text NOT NULL,
    expected_generation bigint NOT NULL,
    target_generation bigint NOT NULL,
    idempotency_key_mac text NOT NULL,
    canonical_request_mac text NOT NULL,
    fence bigint NOT NULL,
    actor_id text NOT NULL,
    correlation_id text NOT NULL,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    CONSTRAINT system_credential_transition_actor_id_check CHECK (((length(actor_id) >= 1) AND (length(actor_id) <= 256))),
    CONSTRAINT system_credential_transition_canonical_request_mac_check CHECK ((canonical_request_mac ~ '^hmac-sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT system_credential_transition_check CHECK (((owner_tenant_id = target_tenant_id) AND (owner_tenant_id <> '__platform__'::text))),
    CONSTRAINT system_credential_transition_check1 CHECK ((((operation_kind = 'CREATE'::text) AND (expected_generation = 0) AND (target_generation = 1)) OR ((operation_kind = 'ROTATE'::text) AND (expected_generation > 0) AND (target_generation = (expected_generation + 1))))),
    CONSTRAINT system_credential_transition_check2 CHECK (((fence > 0) AND (version > 0))),
    CONSTRAINT system_credential_transition_correlation_id_check CHECK ((((length(correlation_id) >= 1) AND (length(correlation_id) <= 256)) AND (correlation_id !~ '[*]'::text))),
    CONSTRAINT system_credential_transition_expected_generation_check CHECK ((expected_generation >= 0)),
    CONSTRAINT system_credential_transition_idempotency_key_mac_check CHECK ((idempotency_key_mac ~ '^hmac-sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT system_credential_transition_operation_id_check CHECK ((operation_id ~ '^scm_[A-Za-z0-9_-]{20,128}$'::text)),
    CONSTRAINT system_credential_transition_operation_kind_check CHECK ((operation_kind = ANY (ARRAY['CREATE'::text, 'ROTATE'::text]))),
    CONSTRAINT system_credential_transition_operation_phase_check CHECK ((operation_phase = ANY (ARRAY['PREPARED'::text, 'COMMITTED'::text, 'FAILED'::text]))),
    CONSTRAINT system_credential_transition_target_generation_check CHECK ((target_generation > 0))
);

ALTER TABLE ONLY public.system_credential_transition FORCE ROW LEVEL SECURITY;


--
-- Name: system_credential_transition_fence_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.system_credential_transition_fence_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: system_credential_transition_material; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.system_credential_transition_material (
    operation_id text NOT NULL,
    owner_tenant_id text NOT NULL,
    secret_id text NOT NULL,
    target_generation bigint NOT NULL,
    storage_assignment_id text NOT NULL,
    storage_consumer_tenant_id text DEFAULT '__platform__'::text NOT NULL,
    storage_assignment_version bigint NOT NULL,
    fence bigint NOT NULL,
    aad_digest text NOT NULL,
    credential_id text NOT NULL,
    kek_id text NOT NULL,
    kek_version bigint NOT NULL,
    envelope_version bigint NOT NULL,
    encrypted_envelope bytea,
    lifecycle_state text NOT NULL,
    provider_written_at bigint,
    consumed_at bigint,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    CONSTRAINT system_credential_transition_m_storage_consumer_tenant_id_check CHECK ((storage_consumer_tenant_id = '__platform__'::text)),
    CONSTRAINT system_credential_transition_material_aad_digest_check CHECK ((aad_digest ~ '^sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT system_credential_transition_material_check CHECK (((target_generation > 0) AND (storage_assignment_version > 0))),
    CONSTRAINT system_credential_transition_material_check1 CHECK (((fence > 0) AND (envelope_version = fence))),
    CONSTRAINT system_credential_transition_material_check2 CHECK ((((lifecycle_state = 'STAGED'::text) AND (provider_written_at IS NULL) AND (consumed_at IS NULL) AND (octet_length(encrypted_envelope) > 0)) OR ((lifecycle_state = 'PROVIDER_WRITTEN'::text) AND (provider_written_at IS NOT NULL) AND (consumed_at IS NULL) AND (octet_length(encrypted_envelope) > 0)) OR ((lifecycle_state = 'CONSUMED'::text) AND (provider_written_at IS NOT NULL) AND (consumed_at IS NOT NULL) AND (encrypted_envelope IS NULL)))),
    CONSTRAINT system_credential_transition_material_credential_id_check CHECK ((credential_id ~ '^scmt_[a-f0-9]{64}$'::text)),
    CONSTRAINT system_credential_transition_material_kek_id_check CHECK ((length(kek_id) > 0)),
    CONSTRAINT system_credential_transition_material_kek_version_check CHECK ((kek_version > 0)),
    CONSTRAINT system_credential_transition_material_lifecycle_state_check CHECK ((lifecycle_state = ANY (ARRAY['STAGED'::text, 'PROVIDER_WRITTEN'::text, 'CONSUMED'::text]))),
    CONSTRAINT system_credential_transition_material_owner_tenant_id_check CHECK ((owner_tenant_id <> '__platform__'::text)),
    CONSTRAINT system_credential_transition_material_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY public.system_credential_transition_material FORCE ROW LEVEL SECURITY;


--
-- Name: system_credential_use_binding; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.system_credential_use_binding (
    owner_tenant_id text NOT NULL,
    reader_actor_id text NOT NULL,
    secret_id text NOT NULL,
    workload_actor_id text NOT NULL,
    purpose text NOT NULL,
    lifecycle_state text NOT NULL,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    CONSTRAINT system_credential_use_binding_lifecycle_state_check CHECK ((lifecycle_state = ANY (ARRAY['CANDIDATE'::text, 'ACTIVE'::text, 'RETIRED'::text, 'FAILED'::text]))),
    CONSTRAINT system_credential_use_binding_owner_tenant_id_check CHECK ((owner_tenant_id <> '__platform__'::text)),
    CONSTRAINT system_credential_use_binding_reader_actor_id_check CHECK ((((length(reader_actor_id) >= 1) AND (length(reader_actor_id) <= 256)) AND (reader_actor_id !~~ '%*%'::text))),
    CONSTRAINT system_credential_use_binding_version_check CHECK ((version > 0)),
    CONSTRAINT system_credential_use_binding_workload_actor_id_check CHECK ((((length(workload_actor_id) >= 1) AND (length(workload_actor_id) <= 256)) AND (workload_actor_id !~~ '%*%'::text)))
);

ALTER TABLE ONLY public.system_credential_use_binding FORCE ROW LEVEL SECURITY;


--
-- Name: tenant; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant (
    id text NOT NULL,
    tenant_type text NOT NULL,
    name text NOT NULL,
    description text,
    owner_party_id text,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: tenant_bootstrap; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_bootstrap (
    id integer NOT NULL,
    completed_at timestamp with time zone,
    completed_tenant_id text,
    completed_by text,
    CONSTRAINT tenant_bootstrap_id_check CHECK ((id = 1))
);


--
-- Name: tenant_config_execution_lease; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_config_execution_lease (
    tenant_id text NOT NULL,
    lease_key text NOT NULL,
    owner_token text,
    fencing_token bigint NOT NULL,
    lease_expires_at_epoch_ms bigint NOT NULL,
    journal_revision bigint NOT NULL,
    CONSTRAINT tenant_config_execution_lease_fencing_token_check CHECK ((fencing_token > 0)),
    CONSTRAINT tenant_config_execution_lease_journal_revision_check CHECK ((journal_revision >= 0))
);


--
-- Name: tenant_config_property; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_config_property (
    tenant_id text NOT NULL,
    key text NOT NULL,
    value text,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text
);


--
-- Name: tenant_config_security_migration; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_config_security_migration (
    migration_id text NOT NULL,
    affected_rows bigint NOT NULL,
    applied_at_epoch_ms bigint NOT NULL,
    CONSTRAINT tenant_config_security_migration_affected_rows_check CHECK ((affected_rows >= 0)),
    CONSTRAINT tenant_config_security_migration_applied_at_epoch_ms_check CHECK ((applied_at_epoch_ms > 0))
);


--
-- Name: tenant_domain; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_domain (
    id text NOT NULL,
    tenant_id text NOT NULL,
    domain text NOT NULL,
    kind text NOT NULL,
    is_primary integer DEFAULT 0 NOT NULL,
    verified_at timestamp with time zone,
    verification_token text,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: tenant_domain_quota_lock; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_domain_quota_lock (
    lock_key text NOT NULL,
    touched_epoch_ms bigint NOT NULL
);


--
-- Name: tenant_kms_key_assignment; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_kms_key_assignment (
    tenant_id text NOT NULL,
    assignment_id text NOT NULL,
    provider_id text NOT NULL,
    key_id text NOT NULL,
    classification text NOT NULL,
    service_type text,
    service_instance text,
    party_id text,
    relationship_type text,
    purpose text NOT NULL,
    valid_from timestamp with time zone,
    valid_until timestamp with time zone,
    status text NOT NULL,
    target_provider_id text,
    assignment_json text NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: tenant_kms_key_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_kms_key_metadata (
    tenant_id text NOT NULL,
    provider_id text NOT NULL,
    key_id text NOT NULL,
    classification text,
    status text NOT NULL,
    rotate_at timestamp with time zone,
    revoke_at timestamp with time zone,
    rotation_interval text,
    rotated_from text,
    rotated_to text,
    target_provider_id text,
    metadata_json text NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: tenant_kms_key_rotation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_kms_key_rotation (
    tenant_id text NOT NULL,
    rotation_id text NOT NULL,
    old_provider_id text NOT NULL,
    old_key_id text NOT NULL,
    new_provider_id text NOT NULL,
    new_key_id text NOT NULL,
    target_provider_id text,
    status text NOT NULL,
    rotate_at timestamp with time zone,
    rotation_interval text,
    rotation_json text NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: tenant_kms_provider_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_kms_provider_metadata (
    tenant_id text NOT NULL,
    provider_id text NOT NULL,
    classification text,
    status text NOT NULL,
    protected_system_provider integer DEFAULT 0 NOT NULL,
    metadata_json text NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: tenant_provider_binding; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_provider_binding (
    binding_id text NOT NULL,
    tenant_id text NOT NULL,
    offering_id text NOT NULL,
    definition_id text NOT NULL,
    provider_revision bigint NOT NULL,
    opaque_partition text NOT NULL,
    capability_generation bigint NOT NULL,
    lifecycle_state text NOT NULL,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    CONSTRAINT tenant_provider_binding_capability_generation_check CHECK ((capability_generation > 0)),
    CONSTRAINT tenant_provider_binding_lifecycle_state_check CHECK ((lifecycle_state = ANY (ARRAY['CANDIDATE'::text, 'READY'::text, 'ACTIVE'::text, 'SUSPENDED'::text, 'RETAINED'::text, 'RETIRED'::text, 'PURGED'::text, 'FAILED'::text]))),
    CONSTRAINT tenant_provider_binding_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY public.tenant_provider_binding FORCE ROW LEVEL SECURITY;


--
-- Name: tenant_provider_capability_generation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_provider_capability_generation (
    tenant_id text NOT NULL,
    binding_id text NOT NULL,
    capability_generation bigint NOT NULL,
    provider_type text NOT NULL,
    lifecycle_state text NOT NULL,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    retired_at bigint,
    CONSTRAINT tenant_provider_capability_generati_capability_generation_check CHECK ((capability_generation > 0)),
    CONSTRAINT tenant_provider_capability_generation_check CHECK (((retired_at IS NULL) OR (retired_at >= created_at))),
    CONSTRAINT tenant_provider_capability_generation_lifecycle_state_check CHECK ((lifecycle_state = ANY (ARRAY['CANDIDATE'::text, 'READY'::text, 'ACTIVE'::text, 'SUSPENDED'::text, 'RETAINED'::text, 'RETIRED'::text, 'PURGED'::text, 'FAILED'::text]))),
    CONSTRAINT tenant_provider_capability_generation_provider_type_check CHECK ((provider_type = ANY (ARRAY['KMS'::text, 'VAULT'::text, 'AWS_SECRETS_MANAGER'::text]))),
    CONSTRAINT tenant_provider_capability_generation_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY public.tenant_provider_capability_generation FORCE ROW LEVEL SECURITY;


--
-- Name: tenant_provider_capability_material; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_provider_capability_material (
    tenant_id text NOT NULL,
    binding_id text NOT NULL,
    capability_generation bigint NOT NULL,
    credential_field text NOT NULL,
    capability_secret_id text NOT NULL,
    material_generation bigint NOT NULL,
    CONSTRAINT tenant_provider_capability_material_check CHECK ((material_generation = capability_generation)),
    CONSTRAINT tenant_provider_capability_material_credential_field_check CHECK ((credential_field ~ '^[A-Za-z][A-Za-z0-9._-]{0,127}$'::text))
);

ALTER TABLE ONLY public.tenant_provider_capability_material FORCE ROW LEVEL SECURITY;


--
-- Name: tenant_provider_isolation_proof_aws; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_provider_isolation_proof_aws (
    tenant_id text NOT NULL,
    binding_id text NOT NULL,
    capability_generation bigint NOT NULL,
    role_capability_id text NOT NULL,
    account_boundary text NOT NULL,
    backend_binding_digest text NOT NULL,
    auth_principal_digest text NOT NULL,
    external_id_digest text NOT NULL,
    policy_digest text NOT NULL,
    resource_tag_digest text NOT NULL,
    role_trust_verified boolean NOT NULL,
    external_id_verified boolean NOT NULL,
    resource_tag_verified boolean NOT NULL,
    CONSTRAINT tenant_provider_isolation_proof_aw_backend_binding_digest_check CHECK ((backend_binding_digest ~ '^sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT tenant_provider_isolation_proof_aws_account_boundary_check CHECK (((length(account_boundary) >= 1) AND (length(account_boundary) <= 512))),
    CONSTRAINT tenant_provider_isolation_proof_aws_auth_principal_digest_check CHECK ((auth_principal_digest ~ '^sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT tenant_provider_isolation_proof_aws_check CHECK ((role_trust_verified AND external_id_verified AND resource_tag_verified)),
    CONSTRAINT tenant_provider_isolation_proof_aws_external_id_digest_check CHECK ((external_id_digest ~ '^sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT tenant_provider_isolation_proof_aws_policy_digest_check CHECK ((policy_digest ~ '^sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT tenant_provider_isolation_proof_aws_resource_tag_digest_check CHECK ((resource_tag_digest ~ '^sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT tenant_provider_isolation_proof_aws_role_capability_id_check CHECK (((length(role_capability_id) >= 1) AND (length(role_capability_id) <= 512)))
);

ALTER TABLE ONLY public.tenant_provider_isolation_proof_aws FORCE ROW LEVEL SECURITY;


--
-- Name: tenant_provider_isolation_proof_azure; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_provider_isolation_proof_azure (
    tenant_id text NOT NULL,
    binding_id text NOT NULL,
    capability_generation bigint NOT NULL,
    vault_capability_id text NOT NULL,
    identity_boundary text NOT NULL,
    backend_binding_digest text NOT NULL,
    auth_identity_digest text NOT NULL,
    vault_boundary_digest text NOT NULL,
    dedicated_vault_verified boolean NOT NULL,
    scoped_identity_verified boolean NOT NULL,
    CONSTRAINT tenant_provider_isolation_proof_az_backend_binding_digest_check CHECK ((backend_binding_digest ~ '^sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT tenant_provider_isolation_proof_azu_vault_boundary_digest_check CHECK ((vault_boundary_digest ~ '^sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT tenant_provider_isolation_proof_azur_auth_identity_digest_check CHECK ((auth_identity_digest ~ '^sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT tenant_provider_isolation_proof_azure_check CHECK ((dedicated_vault_verified AND scoped_identity_verified)),
    CONSTRAINT tenant_provider_isolation_proof_azure_identity_boundary_check CHECK (((length(identity_boundary) >= 1) AND (length(identity_boundary) <= 512))),
    CONSTRAINT tenant_provider_isolation_proof_azure_vault_capability_id_check CHECK (((length(vault_capability_id) >= 1) AND (length(vault_capability_id) <= 512)))
);

ALTER TABLE ONLY public.tenant_provider_isolation_proof_azure FORCE ROW LEVEL SECURITY;


--
-- Name: tenant_provider_isolation_proof_kms; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_provider_isolation_proof_kms (
    tenant_id text NOT NULL,
    binding_id text NOT NULL,
    capability_generation bigint NOT NULL,
    capability_id text NOT NULL,
    binding_key text NOT NULL,
    backend_key_digest text NOT NULL,
    CONSTRAINT tenant_provider_isolation_proof_kms_backend_key_digest_check CHECK ((backend_key_digest ~ '^sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT tenant_provider_isolation_proof_kms_binding_key_check CHECK (((length(binding_key) >= 1) AND (length(binding_key) <= 512))),
    CONSTRAINT tenant_provider_isolation_proof_kms_capability_id_check CHECK (((length(capability_id) >= 1) AND (length(capability_id) <= 512)))
);

ALTER TABLE ONLY public.tenant_provider_isolation_proof_kms FORCE ROW LEVEL SECURITY;


--
-- Name: tenant_provider_isolation_proof_vault; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_provider_isolation_proof_vault (
    tenant_id text NOT NULL,
    binding_id text NOT NULL,
    capability_generation bigint NOT NULL,
    capability_id text NOT NULL,
    backend_binding_digest text NOT NULL,
    authenticated_policy_digest text NOT NULL,
    namespace_digest text,
    opaque_binding_partition text NOT NULL,
    acl_rule_digest text NOT NULL,
    CONSTRAINT tenant_provider_isolation_pro_authenticated_policy_digest_check CHECK ((authenticated_policy_digest ~ '^sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT tenant_provider_isolation_proof__opaque_binding_partition_check CHECK ((opaque_binding_partition ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT tenant_provider_isolation_proof_va_backend_binding_digest_check CHECK ((backend_binding_digest ~ '^sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT tenant_provider_isolation_proof_vault_acl_rule_digest_check CHECK ((acl_rule_digest ~ '^sha256:[a-f0-9]{64}$'::text)),
    CONSTRAINT tenant_provider_isolation_proof_vault_capability_id_check CHECK (((length(capability_id) >= 1) AND (length(capability_id) <= 512))),
    CONSTRAINT tenant_provider_isolation_proof_vault_namespace_digest_check CHECK (((namespace_digest IS NULL) OR (namespace_digest ~ '^sha256:[a-f0-9]{64}$'::text)))
);

ALTER TABLE ONLY public.tenant_provider_isolation_proof_vault FORCE ROW LEVEL SECURITY;


--
-- Name: tenant_public_endpoint; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_public_endpoint (
    id text NOT NULL,
    tenant_id text NOT NULL,
    service_type text NOT NULL,
    instance_id text,
    host text,
    path_prefix text,
    well_known_path text,
    enabled integer DEFAULT 1 NOT NULL,
    primary_endpoint integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: tenant_registration_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_registration_log (
    log_id text NOT NULL,
    tenant_id text NOT NULL,
    status text NOT NULL,
    isolation_strategy text,
    as_slug text,
    owner_user_id text,
    last_error text,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    completed_at timestamp with time zone
);


--
-- Name: tenant_registration_step_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_registration_step_log (
    log_id text NOT NULL,
    step_id text NOT NULL,
    started_at timestamp with time zone NOT NULL,
    completed_at timestamp with time zone,
    error text
);


--
-- Name: tenant_routing; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_routing (
    tenant_id text NOT NULL,
    parent_tenant_id text,
    slug text NOT NULL,
    status text DEFAULT 'ACTIVE'::text NOT NULL,
    system integer DEFAULT 0 NOT NULL,
    storage_route text,
    storage_isolation text,
    storage_identifier text,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: tenant_secret_delegated_capability; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_secret_delegated_capability (
    capability_id text NOT NULL,
    issued_actor_id text NOT NULL,
    original_platform_actor_id text NOT NULL,
    target_tenant_id text NOT NULL,
    operation text NOT NULL,
    expires_at bigint NOT NULL,
    generation bigint NOT NULL,
    revoked boolean DEFAULT false NOT NULL,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    CONSTRAINT tenant_secret_delegated_capability_capability_id_check CHECK ((capability_id ~ '^cap_[A-Za-z0-9_-]{20,128}$'::text)),
    CONSTRAINT tenant_secret_delegated_capability_expires_at_check CHECK ((expires_at > 0)),
    CONSTRAINT tenant_secret_delegated_capability_generation_check CHECK ((generation > 0)),
    CONSTRAINT tenant_secret_delegated_capability_operation_check CHECK ((operation = ANY (ARRAY['READ'::text, 'CREATE'::text, 'ROTATE'::text, 'PURGE'::text, 'MIGRATE'::text]))),
    CONSTRAINT tenant_secret_delegated_capability_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY public.tenant_secret_delegated_capability FORCE ROW LEVEL SECURITY;


--
-- Name: tenant_secret_delegated_capability_generation_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.tenant_secret_delegated_capability_generation_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tenant_secret_delegated_capability_purpose; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_secret_delegated_capability_purpose (
    capability_id text NOT NULL,
    purpose text NOT NULL,
    CONSTRAINT tenant_secret_delegated_capability_purpose_purpose_check CHECK (((length(purpose) >= 1) AND (length(purpose) <= 256)))
);

ALTER TABLE ONLY public.tenant_secret_delegated_capability_purpose FORCE ROW LEVEL SECURITY;


--
-- Name: tenant_secret_policy_override; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_secret_policy_override (
    tenant_id text NOT NULL,
    allow_tenant_managed_providers boolean NOT NULL,
    allow_platform_offerings boolean NOT NULL,
    require_backend_isolation boolean NOT NULL,
    retention_days integer NOT NULL,
    version bigint NOT NULL,
    updated_at bigint NOT NULL,
    CONSTRAINT tenant_secret_policy_override_retention_days_check CHECK (((retention_days >= 0) AND (retention_days <= 3650))),
    CONSTRAINT tenant_secret_policy_override_tenant_id_check CHECK ((tenant_id <> '__platform__'::text)),
    CONSTRAINT tenant_secret_policy_override_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY public.tenant_secret_policy_override FORCE ROW LEVEL SECURITY;


--
-- Name: tenant_secret_policy_override_provider_type; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_secret_policy_override_provider_type (
    tenant_id text NOT NULL,
    provider_type text NOT NULL,
    CONSTRAINT tenant_secret_policy_override_provider_type_provider_type_check CHECK ((provider_type = ANY (ARRAY['KMS'::text, 'VAULT'::text, 'AZURE_KEY_VAULT'::text, 'AWS_SECRETS_MANAGER'::text])))
);

ALTER TABLE ONLY public.tenant_secret_policy_override_provider_type FORCE ROW LEVEL SECURITY;


--
-- Name: tenant_signup_request; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_signup_request (
    id text NOT NULL,
    email text NOT NULL,
    slug text NOT NULL,
    parent_tenant_id text,
    display_name text NOT NULL,
    verification_token_hash text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    status text NOT NULL,
    ip_hash text,
    created_at timestamp with time zone NOT NULL,
    email_verified_at timestamp with time zone,
    approved_at timestamp with time zone,
    approved_by_id text,
    confirmed_at timestamp with time zone,
    rejected_at timestamp with time zone,
    rejected_reason text,
    registered_tenant_id text,
    registered_at timestamp with time zone,
    failure_reason text,
    last_resend_at timestamp with time zone,
    resend_count integer DEFAULT 0 NOT NULL
);


--
-- Name: tenant_user; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_user (
    tenant_id text NOT NULL,
    user_party_id text NOT NULL,
    status text NOT NULL,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: terms_acceptance; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.terms_acceptance (
    tenant_id text NOT NULL,
    identity_id text NOT NULL,
    version text NOT NULL,
    accepted_at timestamp with time zone NOT NULL
);


--
-- Name: theme_definition; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.theme_definition (
    id text NOT NULL,
    tenant_id text NOT NULL,
    scope text NOT NULL,
    product_type text,
    application_id text,
    variant text,
    name text NOT NULL,
    parent_id text,
    tokens_json text NOT NULL,
    version bigint NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    created_by_user_id text,
    updated_by_user_id text,
    deleted_at timestamp with time zone
);


--
-- Name: theme_definition_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.theme_definition_history (
    tenant_id text NOT NULL,
    definition_id text NOT NULL,
    version bigint NOT NULL,
    snapshot_json text NOT NULL,
    saved_at timestamp with time zone NOT NULL
);


--
-- Name: theme_feature; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.theme_feature (
    tenant_id text NOT NULL,
    product_type text NOT NULL,
    feature_id text NOT NULL,
    definition_json text NOT NULL,
    version bigint NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: theme_stylesheet; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.theme_stylesheet (
    tenant_id text NOT NULL,
    application_id text,
    css text NOT NULL,
    content_hash text NOT NULL,
    version bigint NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: trust_anchor; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_anchor (
    domain_id text NOT NULL,
    anchor_id text NOT NULL,
    identity_identifier_id text NOT NULL,
    evidence_mechanism text NOT NULL,
    origin text NOT NULL,
    organization_identity_id text,
    public_resource_ref text,
    status text NOT NULL,
    valid_from bigint,
    valid_until bigint,
    metadata_json text NOT NULL,
    x509_policy_json text,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    tenant_id text,
    CONSTRAINT ck_trust_anchor_validity CHECK (((valid_until IS NULL) OR (valid_from IS NULL) OR (valid_from < valid_until))),
    CONSTRAINT ck_trust_anchor_version CHECK ((version >= 1)),
    CONSTRAINT ck_trust_anchor_x509_policy CHECK (((x509_policy_json IS NULL) OR (evidence_mechanism = 'X509'::text))),
    CONSTRAINT trust_anchor_evidence_mechanism_check CHECK ((evidence_mechanism = ANY (ARRAY['DID'::text, 'JWK'::text, 'X509'::text, 'OIDFED_ENTITY'::text, 'ISSUER_URI'::text, 'DNS_NAME'::text]))),
    CONSTRAINT trust_anchor_origin_check CHECK ((origin = ANY (ARRAY['IMPORTED'::text, 'TENANT_PUBLIC'::text]))),
    CONSTRAINT trust_anchor_status_check CHECK ((status = ANY (ARRAY['ACTIVE'::text, 'DISABLED'::text, 'EXPIRED'::text, 'REVOKED'::text])))
);


--
-- Name: trust_anchor_admission; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_anchor_admission (
    domain_id text NOT NULL,
    anchor_id text NOT NULL,
    admission_class text NOT NULL,
    constraints_json text,
    CONSTRAINT trust_anchor_admission_admission_class_check CHECK ((admission_class = ANY (ARRAY['CREDENTIAL_ISSUER'::text, 'WALLET_PROVIDER'::text, 'VERIFIER'::text, 'TLS_SERVER_CA'::text, 'CATALOG_SIGNER'::text, 'AUTHORIZATION_SERVER_SIGNER'::text, 'MDOC_VICAL_SIGNER'::text])))
);


--
-- Name: trust_attachment; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_attachment (
    attachment_id text NOT NULL,
    consumer_kind text NOT NULL,
    consumer_id text NOT NULL,
    usage text NOT NULL,
    policy_kind text NOT NULL,
    identity_mode text,
    wallet_evidence_policy text,
    tls_mode text,
    catalog_application text,
    catalog_gate text,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    tenant_id text,
    CONSTRAINT ck_trust_attachment_consumer_kind CHECK ((consumer_kind = ANY (ARRAY['TENANT'::text, 'OID4VCI_ISSUER'::text, 'OID4VCI_ISSUANCE_TEMPLATE'::text, 'OID4VCI_CREDENTIAL_CONFIGURATION'::text, 'OID4VP_VERIFIER'::text, 'OID4VP_DCQL_QUERY'::text, 'OID4VP_VERIFIER_DCQL_BINDING'::text, 'OID4VP_REQUEST_TEMPLATE'::text, 'CONNECTOR_HTTP_ENDPOINT'::text]))),
    CONSTRAINT ck_trust_attachment_policy_shape CHECK ((((policy_kind = 'IDENTITY_ADMISSION'::text) AND (identity_mode = ANY (ARRAY['FAIL_CLOSED'::text, 'UNRESTRICTED'::text])) AND (wallet_evidence_policy = ANY (ARRAY['NONE'::text, 'REQUIRE_VDX_WALLET_UNIT_EVIDENCE'::text])) AND (tls_mode IS NULL) AND (catalog_application IS NULL) AND (catalog_gate IS NULL)) OR ((policy_kind = 'TLS_SERVER'::text) AND (identity_mode IS NULL) AND (wallet_evidence_policy IS NULL) AND (tls_mode = 'FAIL_CLOSED'::text) AND (catalog_application IS NULL) AND (catalog_gate IS NULL)) OR ((policy_kind = 'CATALOG_AUTHORIZATION'::text) AND (identity_mode IS NULL) AND (wallet_evidence_policy IS NULL) AND (tls_mode IS NULL) AND (catalog_application = ANY (ARRAY['QUALIFIED_ONLY'::text, 'ALL_USE_CASES'::text])) AND (catalog_gate = ANY (ARRAY['TYPE_MUST_EXIST'::text, 'TYPE_AND_TRUSTED_AUTHORITIES'::text]))))),
    CONSTRAINT ck_trust_attachment_usage CHECK ((usage = ANY (ARRAY['CREDENTIAL_ISSUER_TRUST'::text, 'WALLET_PROVIDER_ESTABLISHMENT'::text, 'VERIFIER_TRUST'::text, 'CATALOG_AUTHORIZATION'::text, 'TLS_SERVER'::text]))),
    CONSTRAINT ck_trust_attachment_usage_policy CHECK ((((policy_kind = 'IDENTITY_ADMISSION'::text) AND (usage = ANY (ARRAY['CREDENTIAL_ISSUER_TRUST'::text, 'WALLET_PROVIDER_ESTABLISHMENT'::text, 'VERIFIER_TRUST'::text]))) OR ((policy_kind = 'TLS_SERVER'::text) AND (usage = 'TLS_SERVER'::text)) OR ((policy_kind = 'CATALOG_AUTHORIZATION'::text) AND (usage = 'CATALOG_AUTHORIZATION'::text)))),
    CONSTRAINT ck_trust_attachment_version CHECK ((version >= 1)),
    CONSTRAINT ck_trust_attachment_wallet_policy CHECK (((wallet_evidence_policy IS NULL) OR (wallet_evidence_policy = 'NONE'::text) OR (usage = 'WALLET_PROVIDER_ESTABLISHMENT'::text))),
    CONSTRAINT trust_attachment_policy_kind_check CHECK ((policy_kind = ANY (ARRAY['IDENTITY_ADMISSION'::text, 'TLS_SERVER'::text, 'CATALOG_AUTHORIZATION'::text])))
);


--
-- Name: trust_attachment_domain; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_attachment_domain (
    attachment_id text NOT NULL,
    ordinal bigint NOT NULL,
    domain_id text NOT NULL,
    CONSTRAINT ck_trust_attachment_domain_ordinal CHECK ((ordinal >= 0))
);


--
-- Name: trust_catalog; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_catalog (
    catalog_row_key text NOT NULL,
    domain_id text NOT NULL,
    catalog_id text NOT NULL,
    display_name text NOT NULL,
    qualification_profile text NOT NULL,
    publication_mode text NOT NULL,
    status text NOT NULL,
    active_snapshot_id text,
    active_snapshot_activated_at bigint,
    active_snapshot_activated_by text,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    updated_by text,
    disabled_at bigint,
    disabled_by text,
    tenant_id text,
    CONSTRAINT ck_trust_catalog_disabled_audit CHECK ((((status = 'DISABLED'::text) AND (disabled_at IS NOT NULL) AND (disabled_by IS NOT NULL)) OR ((status <> 'DISABLED'::text) AND (disabled_at IS NULL) AND (disabled_by IS NULL)))),
    CONSTRAINT ck_trust_catalog_local_profile CHECK (((qualification_profile = ANY (ARRAY['QUALIFIED'::text, 'NON_QUALIFIED'::text])) AND (publication_mode = ANY (ARRAY['LOCAL_ONLY'::text, 'EXTERNAL_PUBLISHED'::text, 'EDK_HOSTED'::text])) AND ((qualification_profile <> 'QUALIFIED'::text) OR (publication_mode <> 'LOCAL_ONLY'::text)))),
    CONSTRAINT ck_trust_catalog_status_pointer CHECK ((((status = 'DRAFT'::text) AND (active_snapshot_id IS NULL) AND (active_snapshot_activated_at IS NULL) AND (active_snapshot_activated_by IS NULL)) OR ((status = 'ACTIVE'::text) AND (active_snapshot_id IS NOT NULL) AND (active_snapshot_activated_at IS NOT NULL) AND (active_snapshot_activated_by IS NOT NULL)) OR (status = 'DISABLED'::text))),
    CONSTRAINT ck_trust_catalog_version CHECK ((version >= 1))
);


--
-- Name: trust_catalog_snapshot; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_catalog_snapshot (
    snapshot_row_key text NOT NULL,
    catalog_row_key text NOT NULL,
    domain_id text NOT NULL,
    catalog_id text NOT NULL,
    snapshot_id text NOT NULL,
    revision bigint NOT NULL,
    qualification_profile text NOT NULL,
    publication_mode text NOT NULL,
    payload_format text NOT NULL,
    payload_digest text NOT NULL,
    valid_from bigint NOT NULL,
    valid_until bigint,
    stored_at bigint NOT NULL,
    stored_by text NOT NULL,
    CONSTRAINT ck_trust_catalog_snapshot_qualified_validity CHECK (((qualification_profile <> 'QUALIFIED'::text) OR ((valid_until IS NOT NULL) AND (publication_mode <> 'LOCAL_ONLY'::text)))),
    CONSTRAINT ck_trust_catalog_snapshot_revision CHECK ((revision >= 1)),
    CONSTRAINT ck_trust_catalog_snapshot_validity CHECK (((valid_until IS NULL) OR (valid_until >= valid_from)))
);


--
-- Name: trust_catalog_snapshot_artifact; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_catalog_snapshot_artifact (
    snapshot_row_key text NOT NULL,
    artifact_role text NOT NULL,
    artifact_id text NOT NULL,
    artifact_format text NOT NULL,
    artifact_digest text NOT NULL,
    size_bytes bigint NOT NULL,
    CONSTRAINT ck_trust_catalog_snapshot_artifact_role CHECK ((artifact_role = ANY (ARRAY['SOURCE'::text, 'PUBLICATION'::text]))),
    CONSTRAINT ck_trust_catalog_snapshot_artifact_size CHECK ((size_bytes > 0))
);


--
-- Name: trust_catalog_snapshot_provenance; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_catalog_snapshot_provenance (
    snapshot_row_key text NOT NULL,
    provenance_kind text NOT NULL,
    authored_at bigint,
    authored_by text,
    source_uri text,
    retrieved_at bigint,
    source_artifact_role text,
    asserted_issuer text,
    CONSTRAINT ck_trust_catalog_snapshot_provenance_shape CHECK ((((provenance_kind = 'LOCAL'::text) AND (authored_at IS NOT NULL) AND (authored_by IS NOT NULL) AND (source_uri IS NULL) AND (retrieved_at IS NULL) AND (source_artifact_role IS NULL)) OR ((provenance_kind = 'IMPORTED'::text) AND (authored_at IS NULL) AND (authored_by IS NULL) AND (source_uri IS NOT NULL) AND (retrieved_at IS NOT NULL) AND (source_artifact_role = 'SOURCE'::text))))
);


--
-- Name: trust_catalog_snapshot_publication; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_catalog_snapshot_publication (
    snapshot_row_key text NOT NULL,
    publication_kind text NOT NULL,
    publication_uri text,
    publication_artifact_role text,
    published_at bigint,
    retrieved_at bigint,
    CONSTRAINT ck_trust_catalog_snapshot_publication_shape CHECK ((((publication_kind = 'LOCAL'::text) AND (publication_uri IS NULL) AND (publication_artifact_role IS NULL) AND (published_at IS NULL) AND (retrieved_at IS NULL)) OR ((publication_kind = 'EXTERNAL'::text) AND (publication_uri IS NOT NULL) AND (publication_artifact_role = 'PUBLICATION'::text) AND (retrieved_at IS NOT NULL)) OR ((publication_kind = 'HOSTED'::text) AND (publication_uri IS NOT NULL) AND (publication_artifact_role = 'PUBLICATION'::text) AND (published_at IS NOT NULL) AND (retrieved_at IS NULL))))
);


--
-- Name: trust_catalog_snapshot_signature; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_catalog_snapshot_signature (
    snapshot_row_key text NOT NULL,
    signature_format text NOT NULL,
    algorithm text NOT NULL,
    key_id text NOT NULL,
    issuer text NOT NULL,
    signed_artifact_digest text NOT NULL,
    issued_at bigint NOT NULL,
    tenant_id text NOT NULL,
    domain_id text NOT NULL,
    catalog_id text NOT NULL,
    key_fingerprint text NOT NULL,
    verified_at bigint NOT NULL,
    verified_by text NOT NULL,
    CONSTRAINT ck_trust_catalog_snapshot_signature_fingerprint CHECK ((key_fingerprint ~ '^sha256:[0-9a-f]{64}$'::text)),
    CONSTRAINT ck_trust_catalog_snapshot_signature_time CHECK ((verified_at >= issued_at))
);


--
-- Name: trust_catalog_snapshot_validation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_catalog_snapshot_validation (
    snapshot_row_key text NOT NULL,
    validator_id text NOT NULL,
    ruleset_id text NOT NULL,
    validated_at bigint NOT NULL,
    validated_by text NOT NULL
);


--
-- Name: trust_catalog_statement; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_catalog_statement (
    statement_row_key text NOT NULL,
    snapshot_row_key text NOT NULL,
    ordinal bigint NOT NULL,
    statement_id text NOT NULL,
    attestation_type_key text NOT NULL,
    attestation_type_kind text NOT NULL,
    attestation_type_value text NOT NULL,
    schema_id text,
    schema_version text NOT NULL,
    rulebook_uri text NOT NULL,
    attestation_los text NOT NULL,
    binding_type text NOT NULL,
    CONSTRAINT ck_trust_catalog_statement_ordinal CHECK ((ordinal >= 0))
);


--
-- Name: trust_catalog_statement_authority; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_catalog_statement_authority (
    authority_row_key text NOT NULL,
    statement_row_key text NOT NULL,
    ordinal bigint NOT NULL,
    framework_type text NOT NULL,
    authority_value text NOT NULL,
    is_lote text NOT NULL,
    CONSTRAINT ck_trust_catalog_statement_authority_lote CHECK ((is_lote = ANY (ARRAY['TRUE'::text, 'FALSE'::text, 'UNSPECIFIED'::text]))),
    CONSTRAINT ck_trust_catalog_statement_authority_ordinal CHECK ((ordinal >= 0))
);


--
-- Name: trust_catalog_statement_format; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_catalog_statement_format (
    statement_row_key text NOT NULL,
    ordinal bigint NOT NULL,
    format_identifier text NOT NULL,
    CONSTRAINT ck_trust_catalog_statement_format_ordinal CHECK ((ordinal >= 0))
);


--
-- Name: trust_catalog_statement_schema_uri; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_catalog_statement_schema_uri (
    schema_uri_row_key text NOT NULL,
    statement_row_key text NOT NULL,
    ordinal bigint NOT NULL,
    format_identifier text NOT NULL,
    uri text NOT NULL,
    CONSTRAINT ck_trust_catalog_statement_schema_uri_ordinal CHECK ((ordinal >= 0))
);


--
-- Name: trust_domain; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_domain (
    domain_id text NOT NULL,
    display_name text NOT NULL,
    description text,
    status text NOT NULL,
    valid_from bigint,
    valid_until bigint,
    version bigint NOT NULL,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    tenant_id text,
    CONSTRAINT ck_trust_domain_validity CHECK (((valid_until IS NULL) OR (valid_from IS NULL) OR (valid_from < valid_until))),
    CONSTRAINT ck_trust_domain_version CHECK ((version >= 1)),
    CONSTRAINT trust_domain_status_check CHECK ((status = ANY (ARRAY['DRAFT'::text, 'ACTIVE'::text, 'DISABLED'::text])))
);


--
-- Name: trust_domain_eligibility_domain; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_domain_eligibility_domain (
    grant_id text NOT NULL,
    ordinal bigint NOT NULL,
    domain_id text NOT NULL,
    CONSTRAINT ck_trust_domain_eligibility_domain_ordinal CHECK ((ordinal >= 0))
);


--
-- Name: trust_domain_eligibility_grant; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_domain_eligibility_grant (
    grant_id text NOT NULL,
    subject_consumer_kind text NOT NULL,
    usage text NOT NULL,
    version bigint NOT NULL,
    tenant_id text,
    CONSTRAINT ck_trust_domain_eligibility_grant_key CHECK (((subject_consumer_kind = ANY (ARRAY['TENANT'::text, 'OID4VCI_ISSUER'::text, 'OID4VCI_ISSUANCE_TEMPLATE'::text, 'OID4VCI_CREDENTIAL_CONFIGURATION'::text, 'OID4VP_VERIFIER'::text, 'OID4VP_DCQL_QUERY'::text, 'OID4VP_VERIFIER_DCQL_BINDING'::text, 'OID4VP_REQUEST_TEMPLATE'::text, 'CONNECTOR_HTTP_ENDPOINT'::text])) AND (usage = ANY (ARRAY['CREDENTIAL_ISSUER_TRUST'::text, 'WALLET_PROVIDER_ESTABLISHMENT'::text, 'VERIFIER_TRUST'::text, 'CATALOG_AUTHORIZATION'::text, 'TLS_SERVER'::text])))),
    CONSTRAINT ck_trust_domain_eligibility_grant_version CHECK ((version >= 1))
);


--
-- Name: trust_domain_v2_migration; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_domain_v2_migration (
    migration_id text NOT NULL,
    target_schema_version bigint NOT NULL,
    state text NOT NULL,
    run_id text,
    lease_expires_at bigint,
    graph_digest text,
    legacy_removed boolean NOT NULL,
    started_at bigint,
    updated_at bigint NOT NULL,
    completed_at bigint,
    tenant_id text,
    CONSTRAINT ck_trust_domain_v2_migration_complete CHECK (((state <> 'COMPLETE'::text) OR ((graph_digest IS NOT NULL) AND (completed_at IS NOT NULL) AND legacy_removed))),
    CONSTRAINT ck_trust_domain_v2_migration_state CHECK ((state = ANY (ARRAY['NOT_STARTED'::text, 'RUNNING'::text, 'BLOCKED'::text, 'READY_TO_FINALIZE'::text, 'COMPLETE'::text]))),
    CONSTRAINT ck_trust_domain_v2_migration_version CHECK ((target_schema_version = 7))
);


--
-- Name: trust_domain_v2_migration_issue; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_domain_v2_migration_issue (
    migration_id text NOT NULL,
    issue_id text NOT NULL,
    work_item_id text,
    tenant_id text,
    source_table text NOT NULL,
    source_key_digest text NOT NULL,
    reason_code text NOT NULL,
    blocking boolean NOT NULL,
    remediation_status text NOT NULL,
    resolution_code text,
    resolved_at bigint,
    resolved_by text,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    CONSTRAINT ck_trust_domain_v2_migration_issue_reason CHECK ((reason_code = ANY (ARRAY['ANCHOR_PROVENANCE_UNRESOLVED'::text, 'ANCHOR_ADMISSION_AMBIGUOUS'::text, 'ANCHOR_MECHANISM_INCOMPATIBLE'::text, 'BINDING_TARGET_UNRESOLVED'::text, 'BINDING_PRECEDENCE_AMBIGUOUS'::text, 'DOMAIN_REFERENCE_MISSING'::text, 'SOURCE_GRAPH_INVALID'::text, 'OID4VP_UNRESTRICTED_REASSERTION_REQUIRED'::text, 'OID4VP_CATALOG_CLASSIFICATION_REQUIRED'::text, 'LEGACY_ROW_INVALID'::text]))),
    CONSTRAINT ck_trust_domain_v2_migration_issue_remediation CHECK ((remediation_status = ANY (ARRAY['OPEN'::text, 'RESOLVED'::text]))),
    CONSTRAINT ck_trust_domain_v2_migration_issue_resolution CHECK ((((remediation_status = 'OPEN'::text) AND (resolution_code IS NULL) AND (resolved_at IS NULL) AND (resolved_by IS NULL)) OR ((remediation_status = 'RESOLVED'::text) AND (resolution_code IS NOT NULL) AND (resolved_at IS NOT NULL) AND (resolved_by IS NOT NULL))))
);


--
-- Name: trust_domain_v2_migration_stage; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_domain_v2_migration_stage (
    migration_id text NOT NULL,
    stage_ordinal bigint NOT NULL,
    stage_name text NOT NULL,
    state text NOT NULL,
    attempt bigint NOT NULL,
    run_id text,
    cursor_digest text,
    started_at bigint,
    updated_at bigint NOT NULL,
    completed_at bigint,
    CONSTRAINT ck_trust_domain_v2_migration_stage_attempt CHECK ((attempt >= 0)),
    CONSTRAINT ck_trust_domain_v2_migration_stage_name CHECK ((((stage_ordinal = 0) AND (stage_name = 'DISCOVERY'::text)) OR ((stage_ordinal = 1) AND (stage_name = 'CLASSIFICATION'::text)) OR ((stage_ordinal = 2) AND (stage_name = 'V2_GRAPH_WRITE'::text)) OR ((stage_ordinal = 3) AND (stage_name = 'RECONCILIATION'::text)) OR ((stage_ordinal = 4) AND (stage_name = 'GRAPH_VALIDATION'::text)) OR ((stage_ordinal = 5) AND (stage_name = 'LEGACY_REMOVAL'::text)))),
    CONSTRAINT ck_trust_domain_v2_migration_stage_ordinal CHECK (((stage_ordinal >= 0) AND (stage_ordinal <= 5))),
    CONSTRAINT ck_trust_domain_v2_migration_stage_state CHECK ((state = ANY (ARRAY['PENDING'::text, 'RUNNING'::text, 'BLOCKED'::text, 'COMPLETE'::text])))
);


--
-- Name: trust_domain_v2_migration_work_item; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_domain_v2_migration_work_item (
    migration_id text NOT NULL,
    work_item_id text NOT NULL,
    source_table text NOT NULL,
    source_key_digest text NOT NULL,
    classification text NOT NULL,
    state text NOT NULL,
    target_type text,
    target_key_digest text,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    completed_at bigint,
    CONSTRAINT ck_trust_domain_v2_migration_work_state CHECK ((state = ANY (ARRAY['DISCOVERED'::text, 'CLASSIFIED'::text, 'MATERIALIZED'::text, 'BLOCKED'::text, 'COMPLETE'::text])))
);


--
-- Name: trust_source; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_source (
    domain_id text NOT NULL,
    source_id text NOT NULL,
    kind text NOT NULL,
    enabled boolean NOT NULL,
    active_revision bigint,
    active_snapshot_id text,
    managed_by text NOT NULL,
    managed_at bigint NOT NULL,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    activated_by text,
    activated_at bigint,
    tenant_id text,
    CONSTRAINT ck_trust_source_kind CHECK ((kind = ANY (ARRAY['ETSI_119612_EU_LOTL'::text, 'ETSI_119612_CUSTOM_LOTL'::text, 'MDOC_VICAL'::text])))
);


--
-- Name: trust_source_derived_qeaa_entry; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_source_derived_qeaa_entry (
    domain_id text NOT NULL,
    source_id text NOT NULL,
    revision bigint NOT NULL,
    snapshot_id text NOT NULL,
    provider_service_identity text NOT NULL,
    qeaa_role text NOT NULL,
    service_type text NOT NULL,
    service_status text NOT NULL,
    territory text NOT NULL,
    material_kind text NOT NULL,
    material_reference_or_digest text NOT NULL,
    valid_from bigint,
    valid_until bigint,
    source_list_identity text NOT NULL,
    source_list_uri text NOT NULL,
    source_list_sequence_number bigint NOT NULL,
    CONSTRAINT ck_trust_source_derived_material CHECK ((material_kind = ANY (ARRAY['CERTIFICATE'::text, 'TRUST_ANCHOR'::text]))),
    CONSTRAINT ck_trust_source_derived_role CHECK ((qeaa_role = 'QEAA_ISSUER'::text)),
    CONSTRAINT ck_trust_source_derived_sequence CHECK ((source_list_sequence_number >= 0)),
    CONSTRAINT ck_trust_source_derived_validity CHECK (((valid_until IS NULL) OR (valid_from IS NULL) OR (valid_until >= valid_from)))
);


--
-- Name: trust_source_refresh_attempt; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_source_refresh_attempt (
    domain_id text NOT NULL,
    source_id text NOT NULL,
    revision bigint NOT NULL,
    attempt_id text NOT NULL,
    state text NOT NULL,
    started_at bigint NOT NULL,
    completed_at bigint,
    resulting_snapshot_id text,
    diagnostic_code text,
    diagnostic_message text,
    CONSTRAINT ck_trust_source_refresh_state CHECK ((state = ANY (ARRAY['STARTED'::text, 'SUCCEEDED'::text, 'FAILED'::text]))),
    CONSTRAINT ck_trust_source_refresh_terminal CHECK ((((state = 'STARTED'::text) AND (completed_at IS NULL) AND (resulting_snapshot_id IS NULL) AND (diagnostic_code IS NULL) AND (diagnostic_message IS NULL)) OR ((state = 'SUCCEEDED'::text) AND (completed_at IS NOT NULL) AND (resulting_snapshot_id IS NOT NULL) AND (diagnostic_code IS NULL) AND (diagnostic_message IS NULL)) OR ((state = 'FAILED'::text) AND (completed_at IS NOT NULL) AND (resulting_snapshot_id IS NULL) AND (diagnostic_code IS NOT NULL) AND (diagnostic_message IS NOT NULL)))),
    CONSTRAINT ck_trust_source_refresh_time CHECK (((completed_at IS NULL) OR (completed_at >= started_at)))
);


--
-- Name: trust_source_revision; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_source_revision (
    domain_id text NOT NULL,
    source_id text NOT NULL,
    revision bigint NOT NULL,
    kind text NOT NULL,
    state text NOT NULL,
    url text NOT NULL,
    format text NOT NULL,
    scheme_identity text NOT NULL,
    bootstrap_kind text NOT NULL,
    bootstrap_identity text NOT NULL,
    managed_by text NOT NULL,
    managed_at bigint NOT NULL,
    max_artifact_bytes bigint NOT NULL,
    validation_status text,
    validation_validated_by text,
    validation_validated_at bigint,
    validation_diagnostic_code text,
    validation_diagnostic_message text,
    validation_snapshot_id text,
    active_snapshot_id text,
    mdoc_vical_settings_json text,
    CONSTRAINT ck_trust_source_revision_bootstrap CHECK ((bootstrap_kind = ANY (ARRAY['PRODUCT_PIVOT'::text, 'EXPLICIT_SIGNER_ANCHORS'::text]))),
    CONSTRAINT ck_trust_source_revision_kind CHECK ((kind = ANY (ARRAY['ETSI_119612_EU_LOTL'::text, 'ETSI_119612_CUSTOM_LOTL'::text, 'MDOC_VICAL'::text]))),
    CONSTRAINT ck_trust_source_revision_mdoc_settings CHECK ((((kind = 'MDOC_VICAL'::text) AND (mdoc_vical_settings_json IS NOT NULL)) OR ((kind <> 'MDOC_VICAL'::text) AND (mdoc_vical_settings_json IS NULL)))),
    CONSTRAINT ck_trust_source_revision_size CHECK ((max_artifact_bytes > 0)),
    CONSTRAINT ck_trust_source_revision_state CHECK ((state = ANY (ARRAY['DRAFT'::text, 'VALIDATED'::text, 'ACTIVE'::text, 'FAILED'::text]))),
    CONSTRAINT ck_trust_source_revision_validation CHECK (((validation_status IS NULL) OR (validation_status = ANY (ARRAY['VALIDATED'::text, 'FAILED'::text]))))
);


--
-- Name: trust_source_revision_egress_host; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_source_revision_egress_host (
    domain_id text NOT NULL,
    source_id text NOT NULL,
    revision bigint NOT NULL,
    host text NOT NULL
);


--
-- Name: trust_source_revision_signer_anchor; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_source_revision_signer_anchor (
    domain_id text NOT NULL,
    source_id text NOT NULL,
    revision bigint NOT NULL,
    anchor_id text NOT NULL
);


--
-- Name: trust_source_snapshot; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_source_snapshot (
    domain_id text NOT NULL,
    source_id text NOT NULL,
    revision bigint NOT NULL,
    snapshot_id text NOT NULL,
    signed_issue_time bigint NOT NULL,
    signed_next_update bigint NOT NULL,
    sequence_number bigint NOT NULL,
    stored_at bigint NOT NULL,
    stored_by text NOT NULL,
    CONSTRAINT ck_trust_source_snapshot_sequence CHECK ((sequence_number >= 0)),
    CONSTRAINT ck_trust_source_snapshot_validity CHECK ((signed_next_update >= signed_issue_time))
);


--
-- Name: trust_source_snapshot_artifact; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_source_snapshot_artifact (
    domain_id text NOT NULL,
    source_id text NOT NULL,
    revision bigint NOT NULL,
    snapshot_id text NOT NULL,
    digest text NOT NULL,
    reference text,
    bounded_representation_base64 text
);


--
-- Name: trust_source_validation_evidence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trust_source_validation_evidence (
    domain_id text NOT NULL,
    source_id text NOT NULL,
    revision bigint NOT NULL,
    status text NOT NULL,
    validated_by text NOT NULL,
    validated_at bigint NOT NULL,
    diagnostic_code text,
    diagnostic_message text,
    snapshot_id text,
    CONSTRAINT ck_trust_source_validation_status CHECK ((status = ANY (ARRAY['VALIDATED'::text, 'FAILED'::text])))
);


--
-- Name: usage_policy; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.usage_policy (
    id text NOT NULL,
    tenant_id text NOT NULL,
    name text NOT NULL,
    description text,
    concurrency_limit bigint NOT NULL,
    slot_interval_minutes bigint NOT NULL,
    min_booking_duration_minutes bigint NOT NULL,
    max_booking_duration_minutes bigint,
    buffer_after_minutes bigint NOT NULL,
    max_advance_booking_days bigint,
    max_bookings_per_day bigint,
    max_concurrent_bookings_per_advance_period bigint,
    allow_same_day_booking boolean NOT NULL,
    min_advance_booking_hours bigint,
    requires_approval boolean NOT NULL,
    allow_recurring boolean NOT NULL,
    is_default boolean NOT NULL,
    created_by_id text,
    updated_by_id text,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: user_credential; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_credential (
    id uuid NOT NULL,
    tenant_id text NOT NULL,
    identity_id uuid NOT NULL,
    username_hmac text NOT NULL,
    username_ciphertext text,
    password_hash text NOT NULL,
    hash_algorithm text NOT NULL,
    email_verified_at timestamp with time zone,
    roles text DEFAULT '[]'::text NOT NULL,
    status text DEFAULT 'ACTIVE'::text NOT NULL,
    failed_attempts integer DEFAULT 0 NOT NULL,
    locked_until timestamp with time zone,
    temporary_lockout_count integer DEFAULT 0 NOT NULL,
    last_login_at timestamp with time zone,
    last_login_ip text,
    password_changed_at timestamp with time zone NOT NULL,
    must_change_password_by timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    created_by_id uuid,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id uuid,
    deleted_at timestamp with time zone,
    deleted_by_id uuid
);


--
-- Name: user_party; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_party (
    party_id text NOT NULL,
    tenant_id text NOT NULL,
    username text NOT NULL,
    email text,
    enabled integer NOT NULL,
    user_type text NOT NULL,
    natural_person_id text,
    identity_id text,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: user_role; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_role (
    user_party_id text NOT NULL,
    role_id text NOT NULL,
    tenant_id text NOT NULL,
    created_at timestamp with time zone NOT NULL,
    created_by_id text,
    updated_at timestamp with time zone NOT NULL,
    updated_by_id text,
    deleted_at timestamp with time zone,
    deleted_by_id text
);


--
-- Name: verifier; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.verifier (
    party_id text NOT NULL
);


--
-- Name: verifier_credential_definition; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.verifier_credential_definition (
    credential_definition_id text NOT NULL
);


--
-- Name: _schema_version _schema_version_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public._schema_version
    ADD CONSTRAINT _schema_version_pkey PRIMARY KEY (schema_name);


--
-- Name: activated_license activated_license_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activated_license
    ADD CONSTRAINT activated_license_pkey PRIMARY KEY (id);


--
-- Name: application_login_config application_login_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.application_login_config
    ADD CONSTRAINT application_login_config_pkey PRIMARY KEY (application_id);


--
-- Name: audit_event audit_event_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_event
    ADD CONSTRAINT audit_event_pkey PRIMARY KEY (id);


--
-- Name: auth_rate_limit_bucket auth_rate_limit_bucket_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_rate_limit_bucket
    ADD CONSTRAINT auth_rate_limit_bucket_pkey PRIMARY KEY (tenant_id, operation, remote_ip);


--
-- Name: auth_session auth_session_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_session
    ADD CONSTRAINT auth_session_pkey PRIMARY KEY (session_id);


--
-- Name: authorization_server_hosted_configuration authorization_server_hosted_configuration_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authorization_server_hosted_configuration
    ADD CONSTRAINT authorization_server_hosted_configuration_pkey PRIMARY KEY (tenant_id, authorization_server_id);


--
-- Name: authorization_server_hosted_signing authorization_server_hosted_signing_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authorization_server_hosted_signing
    ADD CONSTRAINT authorization_server_hosted_signing_pkey PRIMARY KEY (tenant_id, authorization_server_id);


--
-- Name: authorization_server_secret_purge_outbox authorization_server_secret_p_tenant_id_resource_handle_rec_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authorization_server_secret_purge_outbox
    ADD CONSTRAINT authorization_server_secret_p_tenant_id_resource_handle_rec_key UNIQUE (tenant_id, resource_handle, record_version);


--
-- Name: authorization_server_secret_purge_outbox authorization_server_secret_purge_outbox_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authorization_server_secret_purge_outbox
    ADD CONSTRAINT authorization_server_secret_purge_outbox_pkey PRIMARY KEY (id);


--
-- Name: back_channel_logout_retry back_channel_logout_retry_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.back_channel_logout_retry
    ADD CONSTRAINT back_channel_logout_retry_pkey PRIMARY KEY (entry_id);


--
-- Name: booking_metadata booking_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_metadata
    ADD CONSTRAINT booking_metadata_pkey PRIMARY KEY (id);


--
-- Name: booking booking_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking
    ADD CONSTRAINT booking_pkey PRIMARY KEY (id);


--
-- Name: booking_verification booking_verification_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_verification
    ADD CONSTRAINT booking_verification_pkey PRIMARY KEY (id);


--
-- Name: command_execution_idempotency command_execution_idempotency_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.command_execution_idempotency
    ADD CONSTRAINT command_execution_idempotency_pkey PRIMARY KEY (tenant_id, command_id, idempotency_key);


--
-- Name: config_setting config_setting_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.config_setting
    ADD CONSTRAINT config_setting_pkey PRIMARY KEY (id);


--
-- Name: did_also_known_as did_also_known_as_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.did_also_known_as
    ADD CONSTRAINT did_also_known_as_pkey PRIMARY KEY (id);


--
-- Name: did_controller did_controller_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.did_controller
    ADD CONSTRAINT did_controller_pkey PRIMARY KEY (id);


--
-- Name: did_document_context did_document_context_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.did_document_context
    ADD CONSTRAINT did_document_context_pkey PRIMARY KEY (id);


--
-- Name: did_equivalent_id did_equivalent_id_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.did_equivalent_id
    ADD CONSTRAINT did_equivalent_id_pkey PRIMARY KEY (id);


--
-- Name: did_key_mapping did_key_mapping_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.did_key_mapping
    ADD CONSTRAINT did_key_mapping_pkey PRIMARY KEY (id);


--
-- Name: did_record did_record_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.did_record
    ADD CONSTRAINT did_record_pkey PRIMARY KEY (id);


--
-- Name: did_service did_service_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.did_service
    ADD CONSTRAINT did_service_pkey PRIMARY KEY (id);


--
-- Name: did_verification_method did_verification_method_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.did_verification_method
    ADD CONSTRAINT did_verification_method_pkey PRIMARY KEY (id);


--
-- Name: did_verification_relationship did_verification_relationship_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.did_verification_relationship
    ADD CONSTRAINT did_verification_relationship_pkey PRIMARY KEY (id);


--
-- Name: electronic_address electronic_address_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.electronic_address
    ADD CONSTRAINT electronic_address_pkey PRIMARY KEY (id);


--
-- Name: event_command_receipt event_command_receipt_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_command_receipt
    ADD CONSTRAINT event_command_receipt_pkey PRIMARY KEY (tenant_id, model_id, stream_id, idempotency_key);


--
-- Name: event_delivery_receipt event_delivery_receipt_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_delivery_receipt
    ADD CONSTRAINT event_delivery_receipt_pkey PRIMARY KEY (tenant_id, consumer_id, consumer_idempotency_key);


--
-- Name: event event_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event
    ADD CONSTRAINT event_pkey PRIMARY KEY (id);


--
-- Name: event_stream_state event_stream_state_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_stream_state
    ADD CONSTRAINT event_stream_state_pkey PRIMARY KEY (tenant_id, model_id, stream_id);


--
-- Name: event_transmission event_transmission_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_transmission
    ADD CONSTRAINT event_transmission_pkey PRIMARY KEY (id);


--
-- Name: global_tenant_secret_policy global_tenant_secret_policy_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.global_tenant_secret_policy
    ADD CONSTRAINT global_tenant_secret_policy_pkey PRIMARY KEY (policy_key);


--
-- Name: global_tenant_secret_policy_provider_type global_tenant_secret_policy_provider_type_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.global_tenant_secret_policy_provider_type
    ADD CONSTRAINT global_tenant_secret_policy_provider_type_pkey PRIMARY KEY (policy_key, provider_type);


--
-- Name: group_ group__pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_
    ADD CONSTRAINT group__pkey PRIMARY KEY (party_id);


--
-- Name: group_membership group_membership_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_membership
    ADD CONSTRAINT group_membership_pkey PRIMARY KEY (id);


--
-- Name: group_party group_party_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_party
    ADD CONSTRAINT group_party_pkey PRIMARY KEY (party_id);


--
-- Name: group_role group_role_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_role
    ADD CONSTRAINT group_role_pkey PRIMARY KEY (group_party_id, role_id);


--
-- Name: identifier_electronic identifier_electronic_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identifier_electronic
    ADD CONSTRAINT identifier_electronic_pkey PRIMARY KEY (identifier_id);


--
-- Name: identifier_registration identifier_registration_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identifier_registration
    ADD CONSTRAINT identifier_registration_pkey PRIMARY KEY (identifier_id);


--
-- Name: identifier_x509 identifier_x509_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identifier_x509
    ADD CONSTRAINT identifier_x509_pkey PRIMARY KEY (identifier_id);


--
-- Name: identity_application_binding identity_application_binding_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_application_binding
    ADD CONSTRAINT identity_application_binding_pkey PRIMARY KEY (id);


--
-- Name: identity_application_session_revocation_outbox identity_application_session__tenant_id_binding_id_binding__key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_application_session_revocation_outbox
    ADD CONSTRAINT identity_application_session__tenant_id_binding_id_binding__key UNIQUE (tenant_id, binding_id, binding_revision);


--
-- Name: identity_application_session_revocation_outbox identity_application_session_revocation_outbox_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_application_session_revocation_outbox
    ADD CONSTRAINT identity_application_session_revocation_outbox_pkey PRIMARY KEY (id);


--
-- Name: identity_identifier identity_identifier_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_identifier
    ADD CONSTRAINT identity_identifier_pkey PRIMARY KEY (id);


--
-- Name: identity_party_binding identity_party_binding_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_party_binding
    ADD CONSTRAINT identity_party_binding_pkey PRIMARY KEY (identity_id, party_id, binding_type, valid_from);


--
-- Name: identity identity_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity
    ADD CONSTRAINT identity_pkey PRIMARY KEY (party_id);


--
-- Name: invitation_batch invitation_batch_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitation_batch
    ADD CONSTRAINT invitation_batch_pkey PRIMARY KEY (id);


--
-- Name: invitation_event invitation_event_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitation_event
    ADD CONSTRAINT invitation_event_pkey PRIMARY KEY (id);


--
-- Name: invitation_hmac_key invitation_hmac_key_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitation_hmac_key
    ADD CONSTRAINT invitation_hmac_key_pkey PRIMARY KEY (tenant_id);


--
-- Name: invitation invitation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitation
    ADD CONSTRAINT invitation_pkey PRIMARY KEY (tenant_id, token_hash);


--
-- Name: invitation invitation_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitation
    ADD CONSTRAINT invitation_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: key_reference key_reference_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.key_reference
    ADD CONSTRAINT key_reference_pkey PRIMARY KEY (id);


--
-- Name: kms_secret_payload kms_secret_payload_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.kms_secret_payload
    ADD CONSTRAINT kms_secret_payload_pkey PRIMARY KEY (consumer_tenant_id, definition_id, revision, address_digest);


--
-- Name: kv_entry kv_entry_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.kv_entry
    ADD CONSTRAINT kv_entry_pkey PRIMARY KEY (id);


--
-- Name: kv_version kv_version_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.kv_version
    ADD CONSTRAINT kv_version_pkey PRIMARY KEY (id);


--
-- Name: kv_versioned_stream kv_versioned_stream_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.kv_versioned_stream
    ADD CONSTRAINT kv_versioned_stream_pkey PRIMARY KEY (id);


--
-- Name: license_runtime_state license_runtime_state_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.license_runtime_state
    ADD CONSTRAINT license_runtime_state_pkey PRIMARY KEY (state_key);


--
-- Name: lote_draft lote_draft_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lote_draft
    ADD CONSTRAINT lote_draft_pkey PRIMARY KEY (tenant_id, domain_id, lote_id);


--
-- Name: lote_published_version lote_published_version_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lote_published_version
    ADD CONSTRAINT lote_published_version_pkey PRIMARY KEY (tenant_id, domain_id, lote_id, version);


--
-- Name: lote_published_version lote_published_version_tenant_id_domain_id_lote_id_sequence_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lote_published_version
    ADD CONSTRAINT lote_published_version_tenant_id_domain_id_lote_id_sequence_key UNIQUE (tenant_id, domain_id, lote_id, sequence_number);


--
-- Name: lote_remote_provider_entry lote_remote_provider_entry_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lote_remote_provider_entry
    ADD CONSTRAINT lote_remote_provider_entry_pkey PRIMARY KEY (tenant_id, domain_id, source_id, snapshot_id, country, provider_id);


--
-- Name: lote_remote_refresh_attempt lote_remote_refresh_attempt_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lote_remote_refresh_attempt
    ADD CONSTRAINT lote_remote_refresh_attempt_pkey PRIMARY KEY (tenant_id, domain_id, source_id, attempt_id);


--
-- Name: lote_remote_revision lote_remote_revision_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lote_remote_revision
    ADD CONSTRAINT lote_remote_revision_pkey PRIMARY KEY (tenant_id, domain_id, source_id, revision);


--
-- Name: lote_remote_snapshot lote_remote_snapshot_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lote_remote_snapshot
    ADD CONSTRAINT lote_remote_snapshot_pkey PRIMARY KEY (tenant_id, domain_id, source_id, snapshot_id);


--
-- Name: lote_remote_snapshot lote_remote_snapshot_tenant_id_domain_id_source_id_revision_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lote_remote_snapshot
    ADD CONSTRAINT lote_remote_snapshot_tenant_id_domain_id_source_id_revision_key UNIQUE (tenant_id, domain_id, source_id, revision, sequence_number);


--
-- Name: lote_remote_source lote_remote_source_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lote_remote_source
    ADD CONSTRAINT lote_remote_source_pkey PRIMARY KEY (tenant_id, domain_id, source_id);


--
-- Name: mdoc_vical_configuration mdoc_vical_configuration_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mdoc_vical_configuration
    ADD CONSTRAINT mdoc_vical_configuration_pkey PRIMARY KEY (domain_id, anchor_id);


--
-- Name: natural_person natural_person_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.natural_person
    ADD CONSTRAINT natural_person_pkey PRIMARY KEY (party_id);


--
-- Name: oauth_client_registration oauth_client_registration_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_client_registration
    ADD CONSTRAINT oauth_client_registration_pkey PRIMARY KEY (tenant_id, authorization_server_id, client_id);


--
-- Name: oauth_signing_key oauth_signing_key_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_signing_key
    ADD CONSTRAINT oauth_signing_key_pkey PRIMARY KEY (tenant_id, kid);


--
-- Name: oauth_signing_key_revision oauth_signing_key_revision_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_signing_key_revision
    ADD CONSTRAINT oauth_signing_key_revision_pkey PRIMARY KEY (tenant_id);


--
-- Name: oid4vci_offer_session_event oid4vci_offer_session_event_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vci_offer_session_event
    ADD CONSTRAINT oid4vci_offer_session_event_pkey PRIMARY KEY (tenant_id, instance_id, protocol_session_id, sequence);


--
-- Name: oid4vci_offer_session_event oid4vci_offer_session_event_tenant_id_instance_id_protocol__key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vci_offer_session_event
    ADD CONSTRAINT oid4vci_offer_session_event_tenant_id_instance_id_protocol__key UNIQUE (tenant_id, instance_id, protocol_session_id, source_event_id);


--
-- Name: oid4vci_offer_session_projection oid4vci_offer_session_projection_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vci_offer_session_projection
    ADD CONSTRAINT oid4vci_offer_session_projection_pkey PRIMARY KEY (tenant_id, instance_id, protocol_session_id);


--
-- Name: oid4vp_auth_session oid4vp_auth_session_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vp_auth_session
    ADD CONSTRAINT oid4vp_auth_session_pkey PRIMARY KEY (session_id);


--
-- Name: oid4vp_authorization_session_event oid4vp_authorization_session__tenant_id_instance_id_protoco_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vp_authorization_session_event
    ADD CONSTRAINT oid4vp_authorization_session__tenant_id_instance_id_protoco_key UNIQUE (tenant_id, instance_id, protocol_session_id, source_event_id);


--
-- Name: oid4vp_authorization_session_event oid4vp_authorization_session_event_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vp_authorization_session_event
    ADD CONSTRAINT oid4vp_authorization_session_event_pkey PRIMARY KEY (tenant_id, instance_id, protocol_session_id, sequence);


--
-- Name: oid4vp_authorization_session_projection oid4vp_authorization_session_projection_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vp_authorization_session_projection
    ADD CONSTRAINT oid4vp_authorization_session_projection_pkey PRIMARY KEY (tenant_id, instance_id, protocol_session_id);


--
-- Name: organization organization_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization
    ADD CONSTRAINT organization_pkey PRIMARY KEY (party_id);


--
-- Name: organization_registration organization_registration_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_registration
    ADD CONSTRAINT organization_registration_pkey PRIMARY KEY (id);


--
-- Name: organization_unit organization_unit_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_unit
    ADD CONSTRAINT organization_unit_pkey PRIMARY KEY (party_id);


--
-- Name: party_external_relationship party_external_relationship_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.party_external_relationship
    ADD CONSTRAINT party_external_relationship_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: party party_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.party
    ADD CONSTRAINT party_pkey PRIMARY KEY (id);


--
-- Name: party_relationship party_relationship_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.party_relationship
    ADD CONSTRAINT party_relationship_pkey PRIMARY KEY (id);


--
-- Name: party_specialization party_specialization_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.party_specialization
    ADD CONSTRAINT party_specialization_pkey PRIMARY KEY (party_id, subtype);


--
-- Name: physical_address physical_address_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.physical_address
    ADD CONSTRAINT physical_address_pkey PRIMARY KEY (id);


--
-- Name: app_party pk_app_party; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_party
    ADD CONSTRAINT pk_app_party PRIMARY KEY (party_id);


--
-- Name: authorization_server_federation_binding pk_authorization_server_federation_binding; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authorization_server_federation_binding
    ADD CONSTRAINT pk_authorization_server_federation_binding PRIMARY KEY (id);


--
-- Name: authorization_server_migration_completion pk_authorization_server_migration_completion; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authorization_server_migration_completion
    ADD CONSTRAINT pk_authorization_server_migration_completion PRIMARY KEY (tenant_id, migration_version);


--
-- Name: authorization_server_migration_ledger pk_authorization_server_migration_ledger; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authorization_server_migration_ledger
    ADD CONSTRAINT pk_authorization_server_migration_ledger PRIMARY KEY (id);


--
-- Name: authorization_server_migration_source_change pk_authorization_server_migration_source_change; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authorization_server_migration_source_change
    ADD CONSTRAINT pk_authorization_server_migration_source_change PRIMARY KEY (id);


--
-- Name: authorization_server_resource pk_authorization_server_resource; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authorization_server_resource
    ADD CONSTRAINT pk_authorization_server_resource PRIMARY KEY (id);


--
-- Name: business_wallet_membership pk_bwm; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_wallet_membership
    ADD CONSTRAINT pk_bwm PRIMARY KEY (id);


--
-- Name: credential_actor_credential_definitions pk_cacd; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credential_actor_credential_definitions
    ADD CONSTRAINT pk_cacd PRIMARY KEY (party_id, credential_definition_id);


--
-- Name: connector_capability_detail pk_connector_cap; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.connector_capability_detail
    ADD CONSTRAINT pk_connector_cap PRIMARY KEY (capability_id);


--
-- Name: credential_actor pk_credential_actor; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credential_actor
    ADD CONSTRAINT pk_credential_actor PRIMARY KEY (party_id);


--
-- Name: credential_definition pk_credential_definition; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credential_definition
    ADD CONSTRAINT pk_credential_definition PRIMARY KEY (id);


--
-- Name: credential_template pk_credential_template; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credential_template
    ADD CONSTRAINT pk_credential_template PRIMARY KEY (party_id);


--
-- Name: credential_template_claim pk_credential_template_claim; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credential_template_claim
    ADD CONSTRAINT pk_credential_template_claim PRIMARY KEY (id);


--
-- Name: credential_template_claim_display pk_credential_template_claim_display; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credential_template_claim_display
    ADD CONSTRAINT pk_credential_template_claim_display PRIMARY KEY (id);


--
-- Name: credential_templates_schemas pk_credential_templates_schemas; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credential_templates_schemas
    ADD CONSTRAINT pk_credential_templates_schemas PRIMARY KEY (party_id, schema_id);


--
-- Name: issuer pk_issuer; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issuer
    ADD CONSTRAINT pk_issuer PRIMARY KEY (party_id);


--
-- Name: issuer_credential_definition pk_issuer_credential_definition; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issuer_credential_definition
    ADD CONSTRAINT pk_issuer_credential_definition PRIMARY KEY (credential_definition_id);


--
-- Name: kv_version_link pk_kv_version_link; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.kv_version_link
    ADD CONSTRAINT pk_kv_version_link PRIMARY KEY (stream_id, version_id);


--
-- Name: metadata_snapshot pk_ms; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.metadata_snapshot
    ADD CONSTRAINT pk_ms PRIMARY KEY (id);


--
-- Name: oauth2_as_capability pk_oauth2_as_cap; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth2_as_capability
    ADD CONSTRAINT pk_oauth2_as_cap PRIMARY KEY (capability_id);


--
-- Name: oid4vci_authorization_server_override pk_oid4vci_authorization_server_override; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vci_authorization_server_override
    ADD CONSTRAINT pk_oid4vci_authorization_server_override PRIMARY KEY (id);


--
-- Name: oid4vci_issuer_capability pk_oid4vci_cap; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vci_issuer_capability
    ADD CONSTRAINT pk_oid4vci_cap PRIMARY KEY (capability_id);


--
-- Name: oid4vci_issuer pk_oid4vci_issuer; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vci_issuer
    ADD CONSTRAINT pk_oid4vci_issuer PRIMARY KEY (party_id);


--
-- Name: oid4vci_issuer_authorization_server_binding pk_oid4vci_issuer_authorization_server_binding; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vci_issuer_authorization_server_binding
    ADD CONSTRAINT pk_oid4vci_issuer_authorization_server_binding PRIMARY KEY (id);


--
-- Name: oid4vci_issuer_protocol_profile pk_oid4vci_issuer_protocol_profile; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vci_issuer_protocol_profile
    ADD CONSTRAINT pk_oid4vci_issuer_protocol_profile PRIMARY KEY (id);


--
-- Name: oid4vci_override_projection_outbox pk_oid4vci_override_projection_outbox; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vci_override_projection_outbox
    ADD CONSTRAINT pk_oid4vci_override_projection_outbox PRIMARY KEY (id);


--
-- Name: oid4vci_profile_audit_outbox pk_oid4vci_profile_audit_outbox; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vci_profile_audit_outbox
    ADD CONSTRAINT pk_oid4vci_profile_audit_outbox PRIMARY KEY (id);


--
-- Name: oid4vp_verifier_capability pk_oid4vp_cap; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vp_verifier_capability
    ADD CONSTRAINT pk_oid4vp_cap PRIMARY KEY (capability_id);


--
-- Name: oid4vp_verifier pk_oid4vp_verifier; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vp_verifier
    ADD CONSTRAINT pk_oid4vp_verifier PRIMARY KEY (party_id);


--
-- Name: software_assignment pk_sa; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.software_assignment
    ADD CONSTRAINT pk_sa PRIMARY KEY (id);


--
-- Name: software_capability_binding pk_scab; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.software_capability_binding
    ADD CONSTRAINT pk_scab PRIMARY KEY (id);


--
-- Name: software_config_binding pk_scb; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.software_config_binding
    ADD CONSTRAINT pk_scb PRIMARY KEY (id);


--
-- Name: schema_object pk_schema_object; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_object
    ADD CONSTRAINT pk_schema_object PRIMARY KEY (id);


--
-- Name: software_credential pk_scred; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.software_credential
    ADD CONSTRAINT pk_scred PRIMARY KEY (id);


--
-- Name: software_deployment pk_sd; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.software_deployment
    ADD CONSTRAINT pk_sd PRIMARY KEY (id);


--
-- Name: software_endpoint pk_se; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.software_endpoint
    ADD CONSTRAINT pk_se PRIMARY KEY (id);


--
-- Name: server_party pk_server_party; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.server_party
    ADD CONSTRAINT pk_server_party PRIMARY KEY (party_id);


--
-- Name: service_instance_quota_lock pk_service_instance_quota_lock; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_instance_quota_lock
    ADD CONSTRAINT pk_service_instance_quota_lock PRIMARY KEY (tenant_id, service_type);


--
-- Name: service_instance_quota_reservation pk_service_instance_quota_reservation; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_instance_quota_reservation
    ADD CONSTRAINT pk_service_instance_quota_reservation PRIMARY KEY (id);


--
-- Name: software_capability pk_software_capability; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.software_capability
    ADD CONSTRAINT pk_software_capability PRIMARY KEY (id);


--
-- Name: software_party pk_software_party; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.software_party
    ADD CONSTRAINT pk_software_party PRIMARY KEY (party_id);


--
-- Name: trust_anchor pk_trust_anchor; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_anchor
    ADD CONSTRAINT pk_trust_anchor PRIMARY KEY (domain_id, anchor_id);


--
-- Name: trust_anchor_admission pk_trust_anchor_admission; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_anchor_admission
    ADD CONSTRAINT pk_trust_anchor_admission PRIMARY KEY (domain_id, anchor_id, admission_class);


--
-- Name: trust_attachment pk_trust_attachment; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_attachment
    ADD CONSTRAINT pk_trust_attachment PRIMARY KEY (attachment_id);


--
-- Name: trust_attachment_domain pk_trust_attachment_domain; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_attachment_domain
    ADD CONSTRAINT pk_trust_attachment_domain PRIMARY KEY (attachment_id, ordinal);


--
-- Name: trust_catalog pk_trust_catalog; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog
    ADD CONSTRAINT pk_trust_catalog PRIMARY KEY (catalog_row_key);


--
-- Name: trust_catalog_snapshot pk_trust_catalog_snapshot; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_snapshot
    ADD CONSTRAINT pk_trust_catalog_snapshot PRIMARY KEY (snapshot_row_key);


--
-- Name: trust_catalog_snapshot_artifact pk_trust_catalog_snapshot_artifact; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_snapshot_artifact
    ADD CONSTRAINT pk_trust_catalog_snapshot_artifact PRIMARY KEY (snapshot_row_key, artifact_role);


--
-- Name: trust_catalog_snapshot_provenance pk_trust_catalog_snapshot_provenance; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_snapshot_provenance
    ADD CONSTRAINT pk_trust_catalog_snapshot_provenance PRIMARY KEY (snapshot_row_key);


--
-- Name: trust_catalog_snapshot_publication pk_trust_catalog_snapshot_publication; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_snapshot_publication
    ADD CONSTRAINT pk_trust_catalog_snapshot_publication PRIMARY KEY (snapshot_row_key);


--
-- Name: trust_catalog_snapshot_signature pk_trust_catalog_snapshot_signature; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_snapshot_signature
    ADD CONSTRAINT pk_trust_catalog_snapshot_signature PRIMARY KEY (snapshot_row_key);


--
-- Name: trust_catalog_snapshot_validation pk_trust_catalog_snapshot_validation; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_snapshot_validation
    ADD CONSTRAINT pk_trust_catalog_snapshot_validation PRIMARY KEY (snapshot_row_key);


--
-- Name: trust_catalog_statement pk_trust_catalog_statement; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_statement
    ADD CONSTRAINT pk_trust_catalog_statement PRIMARY KEY (statement_row_key);


--
-- Name: trust_catalog_statement_authority pk_trust_catalog_statement_authority; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_statement_authority
    ADD CONSTRAINT pk_trust_catalog_statement_authority PRIMARY KEY (authority_row_key);


--
-- Name: trust_catalog_statement_format pk_trust_catalog_statement_format; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_statement_format
    ADD CONSTRAINT pk_trust_catalog_statement_format PRIMARY KEY (statement_row_key, format_identifier);


--
-- Name: trust_catalog_statement_schema_uri pk_trust_catalog_statement_schema_uri; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_statement_schema_uri
    ADD CONSTRAINT pk_trust_catalog_statement_schema_uri PRIMARY KEY (schema_uri_row_key);


--
-- Name: trust_domain pk_trust_domain; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_domain
    ADD CONSTRAINT pk_trust_domain PRIMARY KEY (domain_id);


--
-- Name: trust_domain_eligibility_domain pk_trust_domain_eligibility_domain; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_domain_eligibility_domain
    ADD CONSTRAINT pk_trust_domain_eligibility_domain PRIMARY KEY (grant_id, ordinal);


--
-- Name: trust_domain_eligibility_grant pk_trust_domain_eligibility_grant; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_domain_eligibility_grant
    ADD CONSTRAINT pk_trust_domain_eligibility_grant PRIMARY KEY (grant_id);


--
-- Name: trust_domain_v2_migration pk_trust_domain_v2_migration; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_domain_v2_migration
    ADD CONSTRAINT pk_trust_domain_v2_migration PRIMARY KEY (migration_id);


--
-- Name: trust_domain_v2_migration_issue pk_trust_domain_v2_migration_issue; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_domain_v2_migration_issue
    ADD CONSTRAINT pk_trust_domain_v2_migration_issue PRIMARY KEY (migration_id, issue_id);


--
-- Name: trust_domain_v2_migration_stage pk_trust_domain_v2_migration_stage; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_domain_v2_migration_stage
    ADD CONSTRAINT pk_trust_domain_v2_migration_stage PRIMARY KEY (migration_id, stage_ordinal);


--
-- Name: trust_domain_v2_migration_work_item pk_trust_domain_v2_migration_work_item; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_domain_v2_migration_work_item
    ADD CONSTRAINT pk_trust_domain_v2_migration_work_item PRIMARY KEY (migration_id, work_item_id);


--
-- Name: trust_source pk_trust_source; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_source
    ADD CONSTRAINT pk_trust_source PRIMARY KEY (domain_id, source_id);


--
-- Name: trust_source_derived_qeaa_entry pk_trust_source_derived_qeaa_entry; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_source_derived_qeaa_entry
    ADD CONSTRAINT pk_trust_source_derived_qeaa_entry PRIMARY KEY (domain_id, source_id, revision, snapshot_id, provider_service_identity);


--
-- Name: trust_source_refresh_attempt pk_trust_source_refresh_attempt; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_source_refresh_attempt
    ADD CONSTRAINT pk_trust_source_refresh_attempt PRIMARY KEY (domain_id, source_id, attempt_id);


--
-- Name: trust_source_revision pk_trust_source_revision; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_source_revision
    ADD CONSTRAINT pk_trust_source_revision PRIMARY KEY (domain_id, source_id, revision);


--
-- Name: trust_source_revision_egress_host pk_trust_source_revision_egress_host; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_source_revision_egress_host
    ADD CONSTRAINT pk_trust_source_revision_egress_host PRIMARY KEY (domain_id, source_id, revision, host);


--
-- Name: trust_source_revision_signer_anchor pk_trust_source_revision_signer_anchor; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_source_revision_signer_anchor
    ADD CONSTRAINT pk_trust_source_revision_signer_anchor PRIMARY KEY (domain_id, source_id, revision, anchor_id);


--
-- Name: trust_source_snapshot pk_trust_source_snapshot; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_source_snapshot
    ADD CONSTRAINT pk_trust_source_snapshot PRIMARY KEY (domain_id, source_id, revision, snapshot_id);


--
-- Name: trust_source_snapshot_artifact pk_trust_source_snapshot_artifact; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_source_snapshot_artifact
    ADD CONSTRAINT pk_trust_source_snapshot_artifact PRIMARY KEY (domain_id, source_id, revision, snapshot_id);


--
-- Name: trust_source_validation_evidence pk_trust_source_validation_evidence; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_source_validation_evidence
    ADD CONSTRAINT pk_trust_source_validation_evidence PRIMARY KEY (domain_id, source_id, revision);


--
-- Name: verifier pk_verifier; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.verifier
    ADD CONSTRAINT pk_verifier PRIMARY KEY (party_id);


--
-- Name: verifier_credential_definition pk_verifier_credential_definition; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.verifier_credential_definition
    ADD CONSTRAINT pk_verifier_credential_definition PRIMARY KEY (credential_definition_id);


--
-- Name: platform_bootstrap_credential platform_bootstrap_credential_credential_id_generation_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_bootstrap_credential
    ADD CONSTRAINT platform_bootstrap_credential_credential_id_generation_key UNIQUE (credential_id, generation);


--
-- Name: platform_bootstrap_credential_generation platform_bootstrap_credential_generation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_bootstrap_credential_generation
    ADD CONSTRAINT platform_bootstrap_credential_generation_pkey PRIMARY KEY (credential_id, generation);


--
-- Name: platform_bootstrap_credential platform_bootstrap_credential_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_bootstrap_credential
    ADD CONSTRAINT platform_bootstrap_credential_pkey PRIMARY KEY (credential_id);


--
-- Name: platform_secret_provider_offering platform_secret_provider_offe_offering_id_definition_id_pub_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_secret_provider_offering
    ADD CONSTRAINT platform_secret_provider_offe_offering_id_definition_id_pub_key UNIQUE (offering_id, definition_id, published_revision);


--
-- Name: platform_secret_provider_offering platform_secret_provider_offering_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_secret_provider_offering
    ADD CONSTRAINT platform_secret_provider_offering_pkey PRIMARY KEY (offering_id);


--
-- Name: policy_assignment policy_assignment_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.policy_assignment
    ADD CONSTRAINT policy_assignment_pkey PRIMARY KEY (id);


--
-- Name: quota_counter quota_counter_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quota_counter
    ADD CONSTRAINT quota_counter_pkey PRIMARY KEY (scope, scope_id, quota_key, window_start);


--
-- Name: relationship_employment relationship_employment_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.relationship_employment
    ADD CONSTRAINT relationship_employment_pkey PRIMARY KEY (relationship_id);


--
-- Name: relationship_type relationship_type_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.relationship_type
    ADD CONSTRAINT relationship_type_pkey PRIMARY KEY (type);


--
-- Name: requirement_category requirement_category_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.requirement_category
    ADD CONSTRAINT requirement_category_pkey PRIMARY KEY (id);


--
-- Name: resource_category resource_category_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_category
    ADD CONSTRAINT resource_category_pkey PRIMARY KEY (id);


--
-- Name: resource_group resource_group_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_group
    ADD CONSTRAINT resource_group_pkey PRIMARY KEY (id);


--
-- Name: resource resource_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource
    ADD CONSTRAINT resource_pkey PRIMARY KEY (party_id);


--
-- Name: resource_requirement resource_requirement_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_requirement
    ADD CONSTRAINT resource_requirement_pkey PRIMARY KEY (id);


--
-- Name: resource_schedule resource_schedule_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_schedule
    ADD CONSTRAINT resource_schedule_pkey PRIMARY KEY (id);


--
-- Name: resource_usage_policy resource_usage_policy_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_usage_policy
    ADD CONSTRAINT resource_usage_policy_pkey PRIMARY KEY (id);


--
-- Name: role role_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role
    ADD CONSTRAINT role_pkey PRIMARY KEY (id);


--
-- Name: schedule_rule schedule_rule_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedule_rule
    ADD CONSTRAINT schedule_rule_pkey PRIMARY KEY (id);


--
-- Name: schedule_set_assignment schedule_set_assignment_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedule_set_assignment
    ADD CONSTRAINT schedule_set_assignment_pkey PRIMARY KEY (id);


--
-- Name: schedule_set_inclusion schedule_set_inclusion_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedule_set_inclusion
    ADD CONSTRAINT schedule_set_inclusion_pkey PRIMARY KEY (id);


--
-- Name: schedule_set schedule_set_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedule_set
    ADD CONSTRAINT schedule_set_pkey PRIMARY KEY (id);


--
-- Name: secret_access_grant secret_access_grant_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_access_grant
    ADD CONSTRAINT secret_access_grant_pkey PRIMARY KEY (actor_id, tenant_id, operation, assignment_role, purpose);


--
-- Name: secret_assignment_write_fence secret_assignment_write_fence_migration_id_fence_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_assignment_write_fence
    ADD CONSTRAINT secret_assignment_write_fence_migration_id_fence_key UNIQUE (migration_id, fence);


--
-- Name: secret_assignment_write_fence secret_assignment_write_fence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_assignment_write_fence
    ADD CONSTRAINT secret_assignment_write_fence_pkey PRIMARY KEY (assignment_id, consumer_tenant_id);


--
-- Name: secret_authority_grant secret_authority_grant_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_authority_grant
    ADD CONSTRAINT secret_authority_grant_pkey PRIMARY KEY (manifest_generation, effective_actor_id, authenticated_tenant_id, target_tenant_scope, authority_scope, operation);


--
-- Name: secret_authority_manifest secret_authority_manifest_manifest_digest_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_authority_manifest
    ADD CONSTRAINT secret_authority_manifest_manifest_digest_key UNIQUE (manifest_digest);


--
-- Name: secret_authority_manifest secret_authority_manifest_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_authority_manifest
    ADD CONSTRAINT secret_authority_manifest_pkey PRIMARY KEY (generation);


--
-- Name: secret_collection_version secret_collection_version_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_collection_version
    ADD CONSTRAINT secret_collection_version_pkey PRIMARY KEY (scope_kind, scope_id, collection_kind);


--
-- Name: secret_credential_material_clear_field secret_credential_material_clear_field_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_credential_material_clear_field
    ADD CONSTRAINT secret_credential_material_clear_field_pkey PRIMARY KEY (transition_id, credential_field);


--
-- Name: secret_credential_material_stage secret_credential_material_stage_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_credential_material_stage
    ADD CONSTRAINT secret_credential_material_stage_pkey PRIMARY KEY (transition_id);


--
-- Name: secret_credential_rotation_journal secret_credential_rotation_journal_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_credential_rotation_journal
    ADD CONSTRAINT secret_credential_rotation_journal_pkey PRIMARY KEY (rotation_id);


--
-- Name: secret_initial_tenant_assignment_journal secret_initial_tenant_assignment_journal_assignment_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_initial_tenant_assignment_journal
    ADD CONSTRAINT secret_initial_tenant_assignment_journal_assignment_id_key UNIQUE (assignment_id);


--
-- Name: secret_initial_tenant_assignment_journal secret_initial_tenant_assignment_journal_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_initial_tenant_assignment_journal
    ADD CONSTRAINT secret_initial_tenant_assignment_journal_pkey PRIMARY KEY (transition_id);


--
-- Name: secret_initial_tenant_assignment_journal secret_initial_tenant_assignment_journal_preflight_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_initial_tenant_assignment_journal
    ADD CONSTRAINT secret_initial_tenant_assignment_journal_preflight_id_key UNIQUE (preflight_id);


--
-- Name: secret_initial_tenant_assignment_journal secret_initial_tenant_assignment_journal_tenant_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_initial_tenant_assignment_journal
    ADD CONSTRAINT secret_initial_tenant_assignment_journal_tenant_id_key UNIQUE (tenant_id);


--
-- Name: secret_kms_resource_mutation_binding_result secret_kms_resource_mutation_binding_result_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_kms_resource_mutation_binding_result
    ADD CONSTRAINT secret_kms_resource_mutation_binding_result_pkey PRIMARY KEY (mutation_id, credential_slot);


--
-- Name: secret_kms_resource_mutation secret_kms_resource_mutation_owner_tenant_id_resource_insta_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_kms_resource_mutation
    ADD CONSTRAINT secret_kms_resource_mutation_owner_tenant_id_resource_insta_key UNIQUE (owner_tenant_id, resource_instance_key, operation_kind, idempotency_key_mac);


--
-- Name: secret_kms_resource_mutation secret_kms_resource_mutation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_kms_resource_mutation
    ADD CONSTRAINT secret_kms_resource_mutation_pkey PRIMARY KEY (mutation_id);


--
-- Name: secret_kms_resource_mutation_result secret_kms_resource_mutation_result_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_kms_resource_mutation_result
    ADD CONSTRAINT secret_kms_resource_mutation_result_pkey PRIMARY KEY (mutation_id);


--
-- Name: secret_kms_resource_public_handle secret_kms_resource_public_ha_owner_tenant_id_resource_inst_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_kms_resource_public_handle
    ADD CONSTRAINT secret_kms_resource_public_ha_owner_tenant_id_resource_inst_key UNIQUE (owner_tenant_id, resource_instance_key);


--
-- Name: secret_kms_resource_public_handle secret_kms_resource_public_handle_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_kms_resource_public_handle
    ADD CONSTRAINT secret_kms_resource_public_handle_pkey PRIMARY KEY (public_handle);


--
-- Name: secret_kms_resource_record secret_kms_resource_record_owner_tenant_id_provider_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_kms_resource_record
    ADD CONSTRAINT secret_kms_resource_record_owner_tenant_id_provider_id_key UNIQUE (owner_tenant_id, provider_id);


--
-- Name: secret_kms_resource_record secret_kms_resource_record_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_kms_resource_record
    ADD CONSTRAINT secret_kms_resource_record_pkey PRIMARY KEY (owner_tenant_id, resource_instance_key);


--
-- Name: secret_kms_resource_sharing secret_kms_resource_sharing_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_kms_resource_sharing
    ADD CONSTRAINT secret_kms_resource_sharing_pkey PRIMARY KEY (owner_tenant_id, resource_instance_key);


--
-- Name: secret_kms_resource_sharing_tenant secret_kms_resource_sharing_tenant_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_kms_resource_sharing_tenant
    ADD CONSTRAINT secret_kms_resource_sharing_tenant_pkey PRIMARY KEY (owner_tenant_id, resource_instance_key, offered_tenant_id);


--
-- Name: secret_kms_resource_sharing_withdrawal secret_kms_resource_sharing_withdrawal_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_kms_resource_sharing_withdrawal
    ADD CONSTRAINT secret_kms_resource_sharing_withdrawal_pkey PRIMARY KEY (owner_tenant_id, resource_instance_key, offered_tenant_id);


--
-- Name: secret_migration_action_journal secret_migration_action_journ_migration_id_action_nonce_has_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_migration_action_journal
    ADD CONSTRAINT secret_migration_action_journ_migration_id_action_nonce_has_key UNIQUE (migration_id, action_nonce_hash);


--
-- Name: secret_migration_action_journal secret_migration_action_journa_migration_id_allocated_fence_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_migration_action_journal
    ADD CONSTRAINT secret_migration_action_journa_migration_id_allocated_fence_key UNIQUE (migration_id, allocated_fence);


--
-- Name: secret_migration_action_journal secret_migration_action_journal_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_migration_action_journal
    ADD CONSTRAINT secret_migration_action_journal_pkey PRIMARY KEY (transition_id);


--
-- Name: secret_migration_item secret_migration_item_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_migration_item
    ADD CONSTRAINT secret_migration_item_pkey PRIMARY KEY (migration_id, secret_id);


--
-- Name: secret_migration_journal secret_migration_journal_migration_id_consumer_tenant_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_migration_journal
    ADD CONSTRAINT secret_migration_journal_migration_id_consumer_tenant_id_key UNIQUE (migration_id, consumer_tenant_id);


--
-- Name: secret_migration_journal secret_migration_journal_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_migration_journal
    ADD CONSTRAINT secret_migration_journal_pkey PRIMARY KEY (migration_id);


--
-- Name: secret_offering_provisioning_journal secret_offering_provisioning__tenant_id_offering_id_revisio_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_offering_provisioning_journal
    ADD CONSTRAINT secret_offering_provisioning__tenant_id_offering_id_revisio_key UNIQUE (tenant_id, offering_id, revision);


--
-- Name: secret_offering_provisioning_journal secret_offering_provisioning__tenant_id_tenant_binding_id_c_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_offering_provisioning_journal
    ADD CONSTRAINT secret_offering_provisioning__tenant_id_tenant_binding_id_c_key UNIQUE (tenant_id, tenant_binding_id, capability_generation);


--
-- Name: secret_offering_provisioning_journal secret_offering_provisioning_journal_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_offering_provisioning_journal
    ADD CONSTRAINT secret_offering_provisioning_journal_pkey PRIMARY KEY (transition_id);


--
-- Name: secret_orphan_cleanup_journal secret_orphan_cleanup_journal_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_orphan_cleanup_journal
    ADD CONSTRAINT secret_orphan_cleanup_journal_pkey PRIMARY KEY (cleanup_id);


--
-- Name: secret_permit_replay_state secret_permit_replay_state_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_permit_replay_state
    ADD CONSTRAINT secret_permit_replay_state_pkey PRIMARY KEY (permit_id);


--
-- Name: secret_preflight_journal secret_preflight_journal_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_preflight_journal
    ADD CONSTRAINT secret_preflight_journal_pkey PRIMARY KEY (preflight_id);


--
-- Name: secret_preflight_journal secret_preflight_journal_preflight_id_consumer_tenant_id_ta_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_preflight_journal
    ADD CONSTRAINT secret_preflight_journal_preflight_id_consumer_tenant_id_ta_key UNIQUE (preflight_id, consumer_tenant_id, target_tenant_binding_id, target_definition_id, target_revision);


--
-- Name: secret_preflight_journal secret_preflight_journal_token_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_preflight_journal
    ADD CONSTRAINT secret_preflight_journal_token_hash_key UNIQUE (token_hash);


--
-- Name: secret_provider_assignment secret_provider_assignment_assignment_id_consumer_tenant_i_key1; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_assignment
    ADD CONSTRAINT secret_provider_assignment_assignment_id_consumer_tenant_i_key1 UNIQUE (assignment_id, consumer_tenant_id, definition_id, revision);


--
-- Name: secret_provider_assignment secret_provider_assignment_assignment_id_consumer_tenant_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_assignment
    ADD CONSTRAINT secret_provider_assignment_assignment_id_consumer_tenant_id_key UNIQUE (assignment_id, consumer_tenant_id);


--
-- Name: secret_provider_assignment secret_provider_assignment_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_assignment
    ADD CONSTRAINT secret_provider_assignment_pkey PRIMARY KEY (assignment_id);


--
-- Name: secret_provider_bootstrap_credential_material secret_provider_bootstrap_credential_material_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_bootstrap_credential_material
    ADD CONSTRAINT secret_provider_bootstrap_credential_material_pkey PRIMARY KEY (definition_id, revision, credential_field, material_generation);


--
-- Name: secret_provider_cache_impact secret_provider_cache_impact_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_cache_impact
    ADD CONSTRAINT secret_provider_cache_impact_pkey PRIMARY KEY (impact_id);


--
-- Name: secret_provider_credential_binding secret_provider_credential_binding_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_credential_binding
    ADD CONSTRAINT secret_provider_credential_binding_pkey PRIMARY KEY (definition_id, revision, credential_field);


--
-- Name: secret_provider_definition secret_provider_definition_definition_id_owner_scope_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_definition
    ADD CONSTRAINT secret_provider_definition_definition_id_owner_scope_key UNIQUE (definition_id, owner_scope);


--
-- Name: secret_provider_definition secret_provider_definition_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_definition
    ADD CONSTRAINT secret_provider_definition_pkey PRIMARY KEY (definition_id);


--
-- Name: secret_provider_environment_manifest_item secret_provider_environment_manifest_item_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_environment_manifest_item
    ADD CONSTRAINT secret_provider_environment_manifest_item_pkey PRIMARY KEY (definition_id, revision, managed_secret_id);


--
-- Name: secret_provider_health secret_provider_health_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_health
    ADD CONSTRAINT secret_provider_health_pkey PRIMARY KEY (definition_id, revision);


--
-- Name: secret_provider_kubernetes_mount_manifest_item secret_provider_kubernetes_mount_manifest_item_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_kubernetes_mount_manifest_item
    ADD CONSTRAINT secret_provider_kubernetes_mount_manifest_item_pkey PRIMARY KEY (definition_id, revision, managed_secret_id);


--
-- Name: secret_provider_platform_credential_material secret_provider_platform_credential_material_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_platform_credential_material
    ADD CONSTRAINT secret_provider_platform_credential_material_pkey PRIMARY KEY (definition_id, revision, credential_field, material_generation);


--
-- Name: secret_provider_revision_aws secret_provider_revision_aws_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_revision_aws
    ADD CONSTRAINT secret_provider_revision_aws_pkey PRIMARY KEY (definition_id, revision);


--
-- Name: secret_provider_revision_azure secret_provider_revision_azure_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_revision_azure
    ADD CONSTRAINT secret_provider_revision_azure_pkey PRIMARY KEY (definition_id, revision);


--
-- Name: secret_provider_revision_capability secret_provider_revision_capability_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_revision_capability
    ADD CONSTRAINT secret_provider_revision_capability_pkey PRIMARY KEY (definition_id, revision, capability);


--
-- Name: secret_provider_revision_environment secret_provider_revision_environment_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_revision_environment
    ADD CONSTRAINT secret_provider_revision_environment_pkey PRIMARY KEY (definition_id, revision);


--
-- Name: secret_provider_revision_kms_authority_credential_slot secret_provider_revision_kms_authority_credential_slot_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_revision_kms_authority_credential_slot
    ADD CONSTRAINT secret_provider_revision_kms_authority_credential_slot_pkey PRIMARY KEY (definition_id, revision, credential_slot);


--
-- Name: secret_provider_revision_kms_authority_metadata secret_provider_revision_kms_authority_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_revision_kms_authority_metadata
    ADD CONSTRAINT secret_provider_revision_kms_authority_metadata_pkey PRIMARY KEY (definition_id, revision);


--
-- Name: secret_provider_revision_kms_operation_metadata secret_provider_revision_kms_operation_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_revision_kms_operation_metadata
    ADD CONSTRAINT secret_provider_revision_kms_operation_metadata_pkey PRIMARY KEY (definition_id, revision);


--
-- Name: secret_provider_revision_kms secret_provider_revision_kms_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_revision_kms
    ADD CONSTRAINT secret_provider_revision_kms_pkey PRIMARY KEY (definition_id, revision);


--
-- Name: secret_provider_revision_kubernetes_mount secret_provider_revision_kubernetes_mount_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_revision_kubernetes_mount
    ADD CONSTRAINT secret_provider_revision_kubernetes_mount_pkey PRIMARY KEY (definition_id, revision);


--
-- Name: secret_provider_revision secret_provider_revision_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_revision
    ADD CONSTRAINT secret_provider_revision_pkey PRIMARY KEY (definition_id, revision);


--
-- Name: secret_provider_revision_transition secret_provider_revision_transition_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_revision_transition
    ADD CONSTRAINT secret_provider_revision_transition_pkey PRIMARY KEY (definition_id, revision);


--
-- Name: secret_provider_revision_vault secret_provider_revision_vault_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_revision_vault
    ADD CONSTRAINT secret_provider_revision_vault_pkey PRIMARY KEY (definition_id, revision);


--
-- Name: secret_purge_journal secret_purge_journal_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_purge_journal
    ADD CONSTRAINT secret_purge_journal_pkey PRIMARY KEY (purge_id);


--
-- Name: secret_purge_journal secret_purge_journal_retention_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_purge_journal
    ADD CONSTRAINT secret_purge_journal_retention_id_key UNIQUE (retention_id);


--
-- Name: secret_record_generation secret_record_generation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_record_generation
    ADD CONSTRAINT secret_record_generation_pkey PRIMARY KEY (secret_id, owner_tenant_id, generation);


--
-- Name: secret_record_generation secret_record_generation_secret_id_owner_tenant_id_generati_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_record_generation
    ADD CONSTRAINT secret_record_generation_secret_id_owner_tenant_id_generati_key UNIQUE (secret_id, owner_tenant_id, generation, record_class);


--
-- Name: secret_record secret_record_owner_tenant_id_secret_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_record
    ADD CONSTRAINT secret_record_owner_tenant_id_secret_id_key UNIQUE (owner_tenant_id, secret_id);


--
-- Name: secret_record secret_record_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_record
    ADD CONSTRAINT secret_record_pkey PRIMARY KEY (secret_id);


--
-- Name: secret_record secret_record_secret_id_owner_tenant_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_record
    ADD CONSTRAINT secret_record_secret_id_owner_tenant_id_key UNIQUE (secret_id, owner_tenant_id);


--
-- Name: secret_record secret_record_secret_id_owner_tenant_id_record_class_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_record
    ADD CONSTRAINT secret_record_secret_id_owner_tenant_id_record_class_key UNIQUE (secret_id, owner_tenant_id, record_class);


--
-- Name: secret_record secret_record_secret_id_owner_tenant_id_record_class_purpos_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_record
    ADD CONSTRAINT secret_record_secret_id_owner_tenant_id_record_class_purpos_key UNIQUE (secret_id, owner_tenant_id, record_class, purpose);


--
-- Name: secret_resource_credential_binding secret_resource_credential_binding_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_resource_credential_binding
    ADD CONSTRAINT secret_resource_credential_binding_pkey PRIMARY KEY (owner_tenant_id, resource_kind, resource_instance_key, credential_slot, binding_generation);


--
-- Name: secret_retention_journal secret_retention_journal_migration_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_retention_journal
    ADD CONSTRAINT secret_retention_journal_migration_id_key UNIQUE (migration_id);


--
-- Name: secret_retention_journal secret_retention_journal_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_retention_journal
    ADD CONSTRAINT secret_retention_journal_pkey PRIMARY KEY (retention_id);


--
-- Name: secret_server_kms_resource_binding secret_server_kms_resource_bi_owner_tenant_id_resource_inst_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_server_kms_resource_binding
    ADD CONSTRAINT secret_server_kms_resource_bi_owner_tenant_id_resource_inst_key UNIQUE (owner_tenant_id, resource_instance_key);


--
-- Name: secret_server_kms_resource_binding secret_server_kms_resource_binding_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_server_kms_resource_binding
    ADD CONSTRAINT secret_server_kms_resource_binding_pkey PRIMARY KEY (owner_tenant_id);


--
-- Name: secret_server_kms_resource_binding secret_server_kms_resource_binding_public_handle_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_server_kms_resource_binding
    ADD CONSTRAINT secret_server_kms_resource_binding_public_handle_key UNIQUE (public_handle);


--
-- Name: secret_server_kms_resource_offering secret_server_kms_resource_offering_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_server_kms_resource_offering
    ADD CONSTRAINT secret_server_kms_resource_offering_pkey PRIMARY KEY (product_offering_key);


--
-- Name: secret_tenant_kms_default_provider secret_tenant_kms_default_provider_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_tenant_kms_default_provider
    ADD CONSTRAINT secret_tenant_kms_default_provider_pkey PRIMARY KEY (tenant_id);


--
-- Name: secret_tenant_kms_enabled_provider secret_tenant_kms_enabled_provider_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_tenant_kms_enabled_provider
    ADD CONSTRAINT secret_tenant_kms_enabled_provider_pkey PRIMARY KEY (tenant_id, provider_id);


--
-- Name: secret_transition_bootstrap_material_receipt secret_transition_bootstrap_material_receipt_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_transition_bootstrap_material_receipt
    ADD CONSTRAINT secret_transition_bootstrap_material_receipt_pkey PRIMARY KEY (operation_id, slot_id);


--
-- Name: secret_transition_idempotency secret_transition_idempotency_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_transition_idempotency
    ADD CONSTRAINT secret_transition_idempotency_pkey PRIMARY KEY (scope_kind, scope_id, operation_kind, idempotency_key_mac);


--
-- Name: secret_transition_idempotency secret_transition_idempotency_transition_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_transition_idempotency
    ADD CONSTRAINT secret_transition_idempotency_transition_id_key UNIQUE (transition_id);


--
-- Name: secret_transition_material_slot secret_transition_material_slot_operation_id_field_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_transition_material_slot
    ADD CONSTRAINT secret_transition_material_slot_operation_id_field_name_key UNIQUE (operation_id, field_name);


--
-- Name: secret_transition_material_slot secret_transition_material_slot_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_transition_material_slot
    ADD CONSTRAINT secret_transition_material_slot_pkey PRIMARY KEY (operation_id, slot_id);


--
-- Name: secret_transition_platform_material_receipt secret_transition_platform_material_receipt_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_transition_platform_material_receipt
    ADD CONSTRAINT secret_transition_platform_material_receipt_pkey PRIMARY KEY (operation_id, slot_id);


--
-- Name: secret_value_mutation_journal secret_value_mutation_journal_consumer_tenant_id_idempotenc_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_value_mutation_journal
    ADD CONSTRAINT secret_value_mutation_journal_consumer_tenant_id_idempotenc_key UNIQUE (consumer_tenant_id, idempotency_key_mac);


--
-- Name: secret_value_mutation_journal secret_value_mutation_journal_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_value_mutation_journal
    ADD CONSTRAINT secret_value_mutation_journal_pkey PRIMARY KEY (operation_id);


--
-- Name: service service_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service
    ADD CONSTRAINT service_pkey PRIMARY KEY (party_id);


--
-- Name: session session_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.session
    ADD CONSTRAINT session_pkey PRIMARY KEY (id);


--
-- Name: single_use_object single_use_object_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.single_use_object
    ADD CONSTRAINT single_use_object_pkey PRIMARY KEY (namespace, key);


--
-- Name: subscription_command_override subscription_command_override_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_command_override
    ADD CONSTRAINT subscription_command_override_pkey PRIMARY KEY (subscription_id, command_pattern);


--
-- Name: subscription_feature subscription_feature_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_feature
    ADD CONSTRAINT subscription_feature_pkey PRIMARY KEY (subscription_id, feature_key);


--
-- Name: subscription subscription_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription
    ADD CONSTRAINT subscription_pkey PRIMARY KEY (id);


--
-- Name: subscription_quota subscription_quota_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_quota
    ADD CONSTRAINT subscription_quota_pkey PRIMARY KEY (subscription_id, quota_key);


--
-- Name: system_credential_reference system_credential_reference_owner_tenant_id_workload_actor__key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_credential_reference
    ADD CONSTRAINT system_credential_reference_owner_tenant_id_workload_actor__key UNIQUE (owner_tenant_id, workload_actor_id, purpose, secret_id);


--
-- Name: system_credential_reference system_credential_reference_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_credential_reference
    ADD CONSTRAINT system_credential_reference_pkey PRIMARY KEY (owner_tenant_id, workload_actor_id, purpose);


--
-- Name: system_credential_reference system_credential_reference_secret_id_owner_tenant_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_credential_reference
    ADD CONSTRAINT system_credential_reference_secret_id_owner_tenant_id_key UNIQUE (secret_id, owner_tenant_id);


--
-- Name: system_credential_transition_material system_credential_transition_material_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_credential_transition_material
    ADD CONSTRAINT system_credential_transition_material_pkey PRIMARY KEY (operation_id);


--
-- Name: system_credential_transition system_credential_transition_owner_tenant_id_operation_kind_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_credential_transition
    ADD CONSTRAINT system_credential_transition_owner_tenant_id_operation_kind_key UNIQUE (owner_tenant_id, operation_kind, idempotency_key_mac);


--
-- Name: system_credential_transition system_credential_transition_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_credential_transition
    ADD CONSTRAINT system_credential_transition_pkey PRIMARY KEY (operation_id);


--
-- Name: system_credential_use_binding system_credential_use_binding_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_credential_use_binding
    ADD CONSTRAINT system_credential_use_binding_pkey PRIMARY KEY (owner_tenant_id, reader_actor_id, secret_id);


--
-- Name: tenant_bootstrap tenant_bootstrap_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_bootstrap
    ADD CONSTRAINT tenant_bootstrap_pkey PRIMARY KEY (id);


--
-- Name: tenant_config_execution_lease tenant_config_execution_lease_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_config_execution_lease
    ADD CONSTRAINT tenant_config_execution_lease_pkey PRIMARY KEY (tenant_id, lease_key);


--
-- Name: tenant_config_property tenant_config_property_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_config_property
    ADD CONSTRAINT tenant_config_property_pkey PRIMARY KEY (tenant_id, key);


--
-- Name: tenant_config_security_migration tenant_config_security_migration_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_config_security_migration
    ADD CONSTRAINT tenant_config_security_migration_pkey PRIMARY KEY (migration_id);


--
-- Name: tenant_domain tenant_domain_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_domain
    ADD CONSTRAINT tenant_domain_pkey PRIMARY KEY (id);


--
-- Name: tenant_domain_quota_lock tenant_domain_quota_lock_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_domain_quota_lock
    ADD CONSTRAINT tenant_domain_quota_lock_pkey PRIMARY KEY (lock_key);


--
-- Name: tenant_kms_key_assignment tenant_kms_key_assignment_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_kms_key_assignment
    ADD CONSTRAINT tenant_kms_key_assignment_pkey PRIMARY KEY (tenant_id, assignment_id);


--
-- Name: tenant_kms_key_metadata tenant_kms_key_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_kms_key_metadata
    ADD CONSTRAINT tenant_kms_key_metadata_pkey PRIMARY KEY (tenant_id, provider_id, key_id);


--
-- Name: tenant_kms_key_rotation tenant_kms_key_rotation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_kms_key_rotation
    ADD CONSTRAINT tenant_kms_key_rotation_pkey PRIMARY KEY (tenant_id, rotation_id);


--
-- Name: tenant_kms_provider_metadata tenant_kms_provider_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_kms_provider_metadata
    ADD CONSTRAINT tenant_kms_provider_metadata_pkey PRIMARY KEY (tenant_id, provider_id);


--
-- Name: tenant tenant_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant
    ADD CONSTRAINT tenant_pkey PRIMARY KEY (id);


--
-- Name: tenant_provider_binding tenant_provider_binding_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_provider_binding
    ADD CONSTRAINT tenant_provider_binding_pkey PRIMARY KEY (binding_id);


--
-- Name: tenant_provider_binding tenant_provider_binding_tenant_id_binding_id_capability_gen_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_provider_binding
    ADD CONSTRAINT tenant_provider_binding_tenant_id_binding_id_capability_gen_key UNIQUE (tenant_id, binding_id, capability_generation);


--
-- Name: tenant_provider_binding tenant_provider_binding_tenant_id_binding_id_definition_id__key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_provider_binding
    ADD CONSTRAINT tenant_provider_binding_tenant_id_binding_id_definition_id__key UNIQUE (tenant_id, binding_id, definition_id, provider_revision);


--
-- Name: tenant_provider_binding tenant_provider_binding_tenant_id_binding_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_provider_binding
    ADD CONSTRAINT tenant_provider_binding_tenant_id_binding_id_key UNIQUE (tenant_id, binding_id);


--
-- Name: tenant_provider_binding tenant_provider_binding_tenant_id_offering_id_provider_revi_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_provider_binding
    ADD CONSTRAINT tenant_provider_binding_tenant_id_offering_id_provider_revi_key UNIQUE (tenant_id, offering_id, provider_revision);


--
-- Name: tenant_provider_capability_generation tenant_provider_capability_generation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_provider_capability_generation
    ADD CONSTRAINT tenant_provider_capability_generation_pkey PRIMARY KEY (tenant_id, binding_id, capability_generation);


--
-- Name: tenant_provider_capability_material tenant_provider_capability_ma_capability_secret_id_tenant_i_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_provider_capability_material
    ADD CONSTRAINT tenant_provider_capability_ma_capability_secret_id_tenant_i_key UNIQUE (capability_secret_id, tenant_id, material_generation);


--
-- Name: tenant_provider_capability_material tenant_provider_capability_material_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_provider_capability_material
    ADD CONSTRAINT tenant_provider_capability_material_pkey PRIMARY KEY (tenant_id, binding_id, capability_generation, credential_field);


--
-- Name: tenant_provider_isolation_proof_aws tenant_provider_isolation_proof_aws_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_provider_isolation_proof_aws
    ADD CONSTRAINT tenant_provider_isolation_proof_aws_pkey PRIMARY KEY (tenant_id, binding_id, capability_generation);


--
-- Name: tenant_provider_isolation_proof_azure tenant_provider_isolation_proof_azure_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_provider_isolation_proof_azure
    ADD CONSTRAINT tenant_provider_isolation_proof_azure_pkey PRIMARY KEY (tenant_id, binding_id, capability_generation);


--
-- Name: tenant_provider_isolation_proof_kms tenant_provider_isolation_proof_kms_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_provider_isolation_proof_kms
    ADD CONSTRAINT tenant_provider_isolation_proof_kms_pkey PRIMARY KEY (tenant_id, binding_id, capability_generation);


--
-- Name: tenant_provider_isolation_proof_vault tenant_provider_isolation_proof_vault_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_provider_isolation_proof_vault
    ADD CONSTRAINT tenant_provider_isolation_proof_vault_pkey PRIMARY KEY (tenant_id, binding_id, capability_generation);


--
-- Name: tenant_public_endpoint tenant_public_endpoint_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_public_endpoint
    ADD CONSTRAINT tenant_public_endpoint_pkey PRIMARY KEY (id);


--
-- Name: tenant_registration_log tenant_registration_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_registration_log
    ADD CONSTRAINT tenant_registration_log_pkey PRIMARY KEY (log_id);


--
-- Name: tenant_registration_step_log tenant_registration_step_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_registration_step_log
    ADD CONSTRAINT tenant_registration_step_log_pkey PRIMARY KEY (log_id, step_id);


--
-- Name: tenant_routing tenant_routing_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_routing
    ADD CONSTRAINT tenant_routing_pkey PRIMARY KEY (tenant_id);


--
-- Name: tenant_secret_delegated_capability tenant_secret_delegated_capability_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_secret_delegated_capability
    ADD CONSTRAINT tenant_secret_delegated_capability_pkey PRIMARY KEY (capability_id);


--
-- Name: tenant_secret_delegated_capability_purpose tenant_secret_delegated_capability_purpose_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_secret_delegated_capability_purpose
    ADD CONSTRAINT tenant_secret_delegated_capability_purpose_pkey PRIMARY KEY (capability_id, purpose);


--
-- Name: tenant_secret_policy_override tenant_secret_policy_override_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_secret_policy_override
    ADD CONSTRAINT tenant_secret_policy_override_pkey PRIMARY KEY (tenant_id);


--
-- Name: tenant_secret_policy_override_provider_type tenant_secret_policy_override_provider_type_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_secret_policy_override_provider_type
    ADD CONSTRAINT tenant_secret_policy_override_provider_type_pkey PRIMARY KEY (tenant_id, provider_type);


--
-- Name: tenant_signup_request tenant_signup_request_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_signup_request
    ADD CONSTRAINT tenant_signup_request_pkey PRIMARY KEY (id);


--
-- Name: tenant_user tenant_user_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_user
    ADD CONSTRAINT tenant_user_pkey PRIMARY KEY (tenant_id, user_party_id);


--
-- Name: terms_acceptance terms_acceptance_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.terms_acceptance
    ADD CONSTRAINT terms_acceptance_pkey PRIMARY KEY (tenant_id, identity_id);


--
-- Name: theme_definition_history theme_definition_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.theme_definition_history
    ADD CONSTRAINT theme_definition_history_pkey PRIMARY KEY (tenant_id, definition_id, version);


--
-- Name: theme_definition theme_definition_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.theme_definition
    ADD CONSTRAINT theme_definition_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: theme_feature theme_feature_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.theme_feature
    ADD CONSTRAINT theme_feature_pkey PRIMARY KEY (tenant_id, product_type, feature_id);


--
-- Name: authorization_server_migration_ledger uq_asml_source; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authorization_server_migration_ledger
    ADD CONSTRAINT uq_asml_source UNIQUE (tenant_id, migration_version, source_type, source_key);


--
-- Name: authorization_server_resource uq_asr_capability; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authorization_server_resource
    ADD CONSTRAINT uq_asr_capability UNIQUE (authorization_server_capability_id);


--
-- Name: credential_template_claim uq_ctc_ctid_path; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credential_template_claim
    ADD CONSTRAINT uq_ctc_ctid_path UNIQUE (credential_template_id, path);


--
-- Name: kv_version_link uq_kv_version_parent; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.kv_version_link
    ADD CONSTRAINT uq_kv_version_parent UNIQUE (stream_id, parent_slot);


--
-- Name: kv_version uq_kv_version_stream_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.kv_version
    ADD CONSTRAINT uq_kv_version_stream_id UNIQUE (stream_id, id);


--
-- Name: kv_versioned_stream uq_kv_versioned_stream_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.kv_versioned_stream
    ADD CONSTRAINT uq_kv_versioned_stream_key UNIQUE (store_id, tenant_id, principal_id, session_id, namespace, entry_key);


--
-- Name: oid4vci_authorization_server_override uq_oaso_resource; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vci_authorization_server_override
    ADD CONSTRAINT uq_oaso_resource UNIQUE (tenant_id, issuer_capability_id, resource_kind, resource_id);


--
-- Name: oid4vci_override_projection_outbox uq_oopo_revision; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vci_override_projection_outbox
    ADD CONSTRAINT uq_oopo_revision UNIQUE (override_id, after_revision);


--
-- Name: oid4vci_profile_audit_outbox uq_opao_idempotency; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vci_profile_audit_outbox
    ADD CONSTRAINT uq_opao_idempotency UNIQUE (tenant_id, idempotency_key);


--
-- Name: software_assignment uq_sa_assignment; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.software_assignment
    ADD CONSTRAINT uq_sa_assignment UNIQUE (software_party_id, assignee_party_id);


--
-- Name: software_capability uq_sc_type; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.software_capability
    ADD CONSTRAINT uq_sc_type UNIQUE (party_id, capability_type);


--
-- Name: service_instance_quota_reservation uq_service_instance_quota_reservation_operation; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_instance_quota_reservation
    ADD CONSTRAINT uq_service_instance_quota_reservation_operation UNIQUE (operation_id);


--
-- Name: service_instance_quota_reservation uq_service_instance_quota_reservation_subject; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_instance_quota_reservation
    ADD CONSTRAINT uq_service_instance_quota_reservation_subject UNIQUE (tenant_id, service_type, subject_id);


--
-- Name: trust_attachment_domain uq_trust_attachment_domain; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_attachment_domain
    ADD CONSTRAINT uq_trust_attachment_domain UNIQUE (attachment_id, domain_id);


--
-- Name: trust_attachment uq_trust_attachment_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_attachment
    ADD CONSTRAINT uq_trust_attachment_key UNIQUE (consumer_kind, consumer_id, usage);


--
-- Name: trust_catalog uq_trust_catalog_identity; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog
    ADD CONSTRAINT uq_trust_catalog_identity UNIQUE (domain_id, catalog_id);


--
-- Name: trust_catalog_snapshot_artifact uq_trust_catalog_snapshot_artifact_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_snapshot_artifact
    ADD CONSTRAINT uq_trust_catalog_snapshot_artifact_id UNIQUE (snapshot_row_key, artifact_id, artifact_role);


--
-- Name: trust_catalog_snapshot uq_trust_catalog_snapshot_identity; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_snapshot
    ADD CONSTRAINT uq_trust_catalog_snapshot_identity UNIQUE (catalog_row_key, snapshot_id);


--
-- Name: trust_catalog_snapshot uq_trust_catalog_snapshot_revision; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_snapshot
    ADD CONSTRAINT uq_trust_catalog_snapshot_revision UNIQUE (catalog_row_key, revision);


--
-- Name: trust_catalog_statement_authority uq_trust_catalog_statement_authority_identity; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_statement_authority
    ADD CONSTRAINT uq_trust_catalog_statement_authority_identity UNIQUE (statement_row_key, authority_row_key);


--
-- Name: trust_catalog_statement_authority uq_trust_catalog_statement_authority_ordinal; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_statement_authority
    ADD CONSTRAINT uq_trust_catalog_statement_authority_ordinal UNIQUE (statement_row_key, ordinal);


--
-- Name: trust_catalog_statement_format uq_trust_catalog_statement_format_ordinal; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_statement_format
    ADD CONSTRAINT uq_trust_catalog_statement_format_ordinal UNIQUE (statement_row_key, ordinal);


--
-- Name: trust_catalog_statement uq_trust_catalog_statement_identity; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_statement
    ADD CONSTRAINT uq_trust_catalog_statement_identity UNIQUE (snapshot_row_key, statement_id);


--
-- Name: trust_catalog_statement uq_trust_catalog_statement_ordinal; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_statement
    ADD CONSTRAINT uq_trust_catalog_statement_ordinal UNIQUE (snapshot_row_key, ordinal);


--
-- Name: trust_catalog_statement_schema_uri uq_trust_catalog_statement_schema_uri_identity; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_statement_schema_uri
    ADD CONSTRAINT uq_trust_catalog_statement_schema_uri_identity UNIQUE (statement_row_key, schema_uri_row_key);


--
-- Name: trust_catalog_statement_schema_uri uq_trust_catalog_statement_schema_uri_ordinal; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_statement_schema_uri
    ADD CONSTRAINT uq_trust_catalog_statement_schema_uri_ordinal UNIQUE (statement_row_key, ordinal);


--
-- Name: trust_domain_eligibility_domain uq_trust_domain_eligibility_domain; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_domain_eligibility_domain
    ADD CONSTRAINT uq_trust_domain_eligibility_domain UNIQUE (grant_id, domain_id);


--
-- Name: trust_domain_eligibility_grant uq_trust_domain_eligibility_grant_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_domain_eligibility_grant
    ADD CONSTRAINT uq_trust_domain_eligibility_grant_key UNIQUE (subject_consumer_kind, usage);


--
-- Name: trust_domain_v2_migration uq_trust_domain_v2_migration_singleton; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_domain_v2_migration
    ADD CONSTRAINT uq_trust_domain_v2_migration_singleton UNIQUE (target_schema_version);


--
-- Name: trust_domain_v2_migration_stage uq_trust_domain_v2_migration_stage_name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_domain_v2_migration_stage
    ADD CONSTRAINT uq_trust_domain_v2_migration_stage_name UNIQUE (migration_id, stage_name);


--
-- Name: trust_domain_v2_migration_work_item uq_trust_domain_v2_migration_work_source; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_domain_v2_migration_work_item
    ADD CONSTRAINT uq_trust_domain_v2_migration_work_source UNIQUE (migration_id, source_table, source_key_digest);


--
-- Name: usage_policy usage_policy_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_policy
    ADD CONSTRAINT usage_policy_pkey PRIMARY KEY (id);


--
-- Name: user_credential user_credential_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_credential
    ADD CONSTRAINT user_credential_pkey PRIMARY KEY (id);


--
-- Name: user_party user_party_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_party
    ADD CONSTRAINT user_party_pkey PRIMARY KEY (party_id);


--
-- Name: user_role user_role_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_role
    ADD CONSTRAINT user_role_pkey PRIMARY KEY (user_party_id, role_id);


--
-- Name: booking_metadata_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX booking_metadata_key_idx ON public.booking_metadata USING btree (booking_id, key);


--
-- Name: booking_resource_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX booking_resource_time_idx ON public.booking USING btree (resource_id, start_time, end_time);


--
-- Name: cei_execution_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX cei_execution_id ON public.command_execution_idempotency USING btree (execution_id);


--
-- Name: cei_expiry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cei_expiry ON public.command_execution_idempotency USING btree (expires_at);


--
-- Name: cei_operation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX cei_operation_id ON public.command_execution_idempotency USING btree (operation_id);


--
-- Name: idx_application_login_config_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_application_login_config_tenant ON public.application_login_config USING btree (tenant_id);


--
-- Name: idx_asfb_hosted_enabled_order_live; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_asfb_hosted_enabled_order_live ON public.authorization_server_federation_binding USING btree (tenant_id, hosted_authorization_server_id, enabled, display_order) WHERE (deleted_at IS NULL);


--
-- Name: idx_asfb_hosted_external_live; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_asfb_hosted_external_live ON public.authorization_server_federation_binding USING btree (tenant_id, hosted_authorization_server_id, external_authorization_server_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_asml_tenant_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_asml_tenant_status ON public.authorization_server_migration_ledger USING btree (tenant_id, migration_version, status);


--
-- Name: idx_asmlsc_tenant_ledger; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_asmlsc_tenant_ledger ON public.authorization_server_migration_source_change USING btree (tenant_id, ledger_id);


--
-- Name: idx_asr_tenant_deployment_live; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_asr_tenant_deployment_live ON public.authorization_server_resource USING btree (tenant_id, deployment) WHERE (deleted_at IS NULL);


--
-- Name: idx_asr_tenant_issuer_live; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_asr_tenant_issuer_live ON public.authorization_server_resource USING btree (tenant_id, issuer) WHERE (deleted_at IS NULL);


--
-- Name: idx_asr_tenant_lifecycle_live; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_asr_tenant_lifecycle_live ON public.authorization_server_resource USING btree (tenant_id, lifecycle) WHERE (deleted_at IS NULL);


--
-- Name: idx_asr_tenant_slug_live; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_asr_tenant_slug_live ON public.authorization_server_resource USING btree (tenant_id, slug) WHERE (deleted_at IS NULL);


--
-- Name: idx_audit_command; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_command ON public.audit_event USING btree (command_id, created_at DESC);


--
-- Name: idx_audit_correlation; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_correlation ON public.audit_event USING btree (correlation_id);


--
-- Name: idx_audit_module; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_module ON public.audit_event USING btree (module, created_at DESC);


--
-- Name: idx_audit_tenant_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_tenant_time ON public.audit_event USING btree (tenant_id, created_at DESC);


--
-- Name: idx_audit_trace; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_trace ON public.audit_event USING btree (trace_id);


--
-- Name: idx_auth_rate_limit_last_seen; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_rate_limit_last_seen ON public.auth_rate_limit_bucket USING btree (last_seen);


--
-- Name: idx_auth_session_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_session_expires_at ON public.auth_session USING btree (expires_at);


--
-- Name: idx_auth_session_tenant_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_session_tenant_identity ON public.auth_session USING btree (tenant_id, identity_id);


--
-- Name: idx_auth_session_upstream_sid; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_session_upstream_sid ON public.auth_session USING btree (upstream_issuer, upstream_sid);


--
-- Name: idx_auth_session_upstream_sub; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_session_upstream_sub ON public.auth_session USING btree (upstream_issuer, upstream_sub);


--
-- Name: idx_bc_logout_retry_next_attempt_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bc_logout_retry_next_attempt_at ON public.back_channel_logout_retry USING btree (next_attempt_at);


--
-- Name: idx_bc_logout_retry_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bc_logout_retry_tenant ON public.back_channel_logout_retry USING btree (tenant_id, next_attempt_at);


--
-- Name: idx_bwm_identity_live; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bwm_identity_live ON public.business_wallet_membership USING btree (tenant_id, identity_id, wallet_party_id) WHERE (revoked_at IS NULL);


--
-- Name: idx_bwm_wallet_identity_live; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_bwm_wallet_identity_live ON public.business_wallet_membership USING btree (tenant_id, wallet_party_id, identity_id) WHERE (revoked_at IS NULL);


--
-- Name: idx_config_setting_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_config_setting_key ON public.config_setting USING btree (tenant_id, property_key) WHERE (deleted_at IS NULL);


--
-- Name: idx_config_setting_profile; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_config_setting_profile ON public.config_setting USING btree (tenant_id, profile) WHERE (deleted_at IS NULL);


--
-- Name: idx_config_setting_scope; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_config_setting_scope ON public.config_setting USING btree (tenant_id, scope, scope_identifier) WHERE (deleted_at IS NULL);


--
-- Name: idx_config_setting_theme_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_config_setting_theme_lookup ON public.config_setting USING btree (tenant_id, scope, property_key) WHERE ((deleted_at IS NULL) AND (property_key ~~ 'theme.%'::text));


--
-- Name: idx_config_setting_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_config_setting_unique ON public.config_setting USING btree (application_id, tenant_id, scope, COALESCE(scope_identifier, ''::text), property_key, profile) WHERE (deleted_at IS NULL);


--
-- Name: idx_credential_definition_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_credential_definition_created ON public.credential_definition USING btree (created_at DESC);


--
-- Name: idx_credential_definition_template; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_credential_definition_template ON public.credential_definition USING btree (credential_template_id);


--
-- Name: idx_ctc_template_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ctc_template_id ON public.credential_template_claim USING btree (credential_template_id);


--
-- Name: idx_ctcd_claim_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ctcd_claim_id ON public.credential_template_claim_display USING btree (credential_template_claim_id);


--
-- Name: idx_ctcd_claim_locale_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_ctcd_claim_locale_unique ON public.credential_template_claim_display USING btree (credential_template_claim_id, COALESCE(locale, ''::text));


--
-- Name: idx_design_element_binding_slot; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_design_element_binding_slot ON public.design_element_binding USING btree (tenant_id, product_type, feature_id, element_id, COALESCE(application_id, ''::text), COALESCE(variant, ''::text));


--
-- Name: idx_did_aka_did_record; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_did_aka_did_record ON public.did_also_known_as USING btree (did_record_id);


--
-- Name: idx_did_context_did_record; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_did_context_did_record ON public.did_document_context USING btree (did_record_id);


--
-- Name: idx_did_controller_did_record; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_did_controller_did_record ON public.did_controller USING btree (did_record_id);


--
-- Name: idx_did_equivalent_did_record; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_did_equivalent_did_record ON public.did_equivalent_id USING btree (did_record_id);


--
-- Name: idx_did_keymap_did_record; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_did_keymap_did_record ON public.did_key_mapping USING btree (did_record_id);


--
-- Name: idx_did_keymap_kms; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_did_keymap_kms ON public.did_key_mapping USING btree (kms_provider_id, kms_key_alias);


--
-- Name: idx_did_keymap_vm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_did_keymap_vm ON public.did_key_mapping USING btree (verification_method_id);


--
-- Name: idx_did_record_alias; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_did_record_alias ON public.did_record USING btree (alias);


--
-- Name: idx_did_record_did; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_did_record_did ON public.did_record USING btree (did);


--
-- Name: idx_did_record_tenant_alias_live; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_did_record_tenant_alias_live ON public.did_record USING btree (tenant_id, alias) WHERE ((alias IS NOT NULL) AND (deleted_at IS NULL));


--
-- Name: idx_did_record_tenant_deleted; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_did_record_tenant_deleted ON public.did_record USING btree (tenant_id, deleted_at);


--
-- Name: idx_did_record_tenant_did; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_did_record_tenant_did ON public.did_record USING btree (tenant_id, did) WHERE (deleted_at IS NULL);


--
-- Name: idx_did_record_tenant_web_location_live; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_did_record_tenant_web_location_live ON public.did_record USING btree (tenant_id, web_location) WHERE ((web_location IS NOT NULL) AND (deleted_at IS NULL));


--
-- Name: idx_did_rel_did_record_purpose; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_did_rel_did_record_purpose ON public.did_verification_relationship USING btree (did_record_id, purpose);


--
-- Name: idx_did_service_did_record; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_did_service_did_record ON public.did_service USING btree (did_record_id);


--
-- Name: idx_did_vm_did_record; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_did_vm_did_record ON public.did_verification_method USING btree (did_record_id);


--
-- Name: idx_did_vm_kms; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_did_vm_kms ON public.did_verification_method USING btree (kms_provider_id, kms_key_alias);


--
-- Name: idx_electronic_address_identifier; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_electronic_address_identifier ON public.electronic_address USING btree (identifier_id);


--
-- Name: idx_electronic_address_party; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_electronic_address_party ON public.electronic_address USING btree (party_id);


--
-- Name: idx_event_stream_replay; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_event_stream_replay ON public.event USING btree (tenant_id, model_id, stream_id, stream_sequence) WHERE (stream_id IS NOT NULL);


--
-- Name: idx_event_tenant_category; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_event_tenant_category ON public.event USING btree (tenant_id, category);


--
-- Name: idx_event_tenant_correlation; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_event_tenant_correlation ON public.event USING btree (tenant_id, correlation_id);


--
-- Name: idx_event_tenant_origin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_event_tenant_origin ON public.event USING btree (tenant_id, origin);


--
-- Name: idx_event_tenant_principal; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_event_tenant_principal ON public.event USING btree (tenant_id, principal_id);


--
-- Name: idx_event_tenant_session; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_event_tenant_session ON public.event USING btree (tenant_id, session_id);


--
-- Name: idx_event_tenant_subsystem; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_event_tenant_subsystem ON public.event USING btree (tenant_id, subsystem);


--
-- Name: idx_event_tenant_timestamp; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_event_tenant_timestamp ON public.event USING btree (tenant_id, "timestamp" DESC);


--
-- Name: idx_event_tenant_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_event_tenant_type ON public.event USING btree (tenant_id, type);


--
-- Name: idx_group_membership_group; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_group_membership_group ON public.group_membership USING btree (group_id);


--
-- Name: idx_group_membership_member; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_group_membership_member ON public.group_membership USING btree (member_party_id);


--
-- Name: idx_group_membership_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_group_membership_tenant ON public.group_membership USING btree (tenant_id);


--
-- Name: idx_group_membership_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_group_membership_unique ON public.group_membership USING btree (tenant_id, group_id, member_party_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_group_party_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_group_party_name ON public.group_party USING btree (tenant_id, name);


--
-- Name: idx_group_party_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_group_party_tenant ON public.group_party USING btree (tenant_id);


--
-- Name: idx_group_party_tenant_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_group_party_tenant_name ON public.group_party USING btree (tenant_id, name) WHERE (deleted_at IS NULL);


--
-- Name: idx_group_role_group; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_group_role_group ON public.group_role USING btree (group_party_id);


--
-- Name: idx_group_role_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_group_role_role ON public.group_role USING btree (role_id);


--
-- Name: idx_group_role_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_group_role_tenant ON public.group_role USING btree (tenant_id);


--
-- Name: idx_group_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_group_tenant ON public.group_ USING btree (tenant_id);


--
-- Name: idx_iab_application; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_iab_application ON public.identity_application_binding USING btree (tenant_id, application_id);


--
-- Name: idx_iab_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_iab_identity ON public.identity_application_binding USING btree (tenant_id, identity_id);


--
-- Name: idx_iab_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_iab_unique ON public.identity_application_binding USING btree (tenant_id, identity_id, application_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_identity_identifier_blind; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_identity_identifier_blind ON public.identity_identifier USING btree (tenant_id, identifier_type, value_hmac) WHERE (value_hmac IS NOT NULL);


--
-- Name: idx_identity_identifier_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_identity_identifier_identity ON public.identity_identifier USING btree (identity_id);


--
-- Name: idx_identity_identifier_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_identity_identifier_lookup ON public.identity_identifier USING btree (tenant_id, identifier_type, lookup_value);


--
-- Name: idx_identity_identifier_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_identity_identifier_source ON public.identity_identifier USING btree (tenant_id, source_kind, source_party_id, source_record_id, source_field) WHERE (source_kind IS NOT NULL);


--
-- Name: idx_identity_party_binding_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_identity_party_binding_identity ON public.identity_party_binding USING btree (tenant_id, identity_id);


--
-- Name: idx_identity_party_binding_party; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_identity_party_binding_party ON public.identity_party_binding USING btree (tenant_id, party_id, party_type);


--
-- Name: idx_identity_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_identity_role ON public.identity USING btree (tenant_id, identity_role);


--
-- Name: idx_identity_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_identity_tenant ON public.identity USING btree (tenant_id);


--
-- Name: idx_invitation_batch; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_invitation_batch ON public.invitation USING btree (tenant_id, batch_id);


--
-- Name: idx_invitation_batch_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_invitation_batch_tenant ON public.invitation_batch USING btree (tenant_id, created_at DESC);


--
-- Name: idx_invitation_delivery_state; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_invitation_delivery_state ON public.invitation USING btree (tenant_id, delivery_state, last_action_at);


--
-- Name: idx_invitation_event_invitation; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_invitation_event_invitation ON public.invitation_event USING btree (invitation_id, occurred_at);


--
-- Name: idx_invitation_event_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_invitation_event_tenant ON public.invitation_event USING btree (tenant_id, occurred_at DESC);


--
-- Name: idx_invitation_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_invitation_expires_at ON public.invitation USING btree (expires_at);


--
-- Name: idx_invitation_origin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_invitation_origin ON public.invitation USING btree (tenant_id, origin_kind, origin_id);


--
-- Name: idx_invitation_status_action; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_invitation_status_action ON public.invitation USING btree (tenant_id, status, action, created_at DESC);


--
-- Name: idx_invitation_target; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_invitation_target ON public.invitation USING btree (tenant_id, scope, target_id, created_at DESC);


--
-- Name: idx_key_ref_origin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_key_ref_origin ON public.key_reference USING btree (origin);


--
-- Name: idx_key_ref_tenant_alias_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_key_ref_tenant_alias_provider ON public.key_reference USING btree (tenant_id, alias, provider_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_key_ref_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_key_ref_tenant_id ON public.key_reference USING btree (tenant_id);


--
-- Name: idx_key_ref_tenant_kid; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_key_ref_tenant_kid ON public.key_reference USING btree (tenant_id, kid);


--
-- Name: idx_key_ref_tenant_kid_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_key_ref_tenant_kid_provider ON public.key_reference USING btree (tenant_id, kid, provider_id) WHERE ((deleted_at IS NULL) AND (kid IS NOT NULL));


--
-- Name: idx_key_ref_tenant_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_key_ref_tenant_provider ON public.key_reference USING btree (tenant_id, provider_id);


--
-- Name: idx_kv_entry_expiry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_kv_entry_expiry ON public.kv_entry USING btree (expires_at) WHERE (expires_at IS NOT NULL);


--
-- Name: idx_kv_entry_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_kv_entry_lookup ON public.kv_entry USING btree (store_id, tenant_id, COALESCE(principal_id, ''::text), COALESCE(session_id, ''::text), namespace, entry_key);


--
-- Name: idx_kv_entry_namespace; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_kv_entry_namespace ON public.kv_entry USING btree (store_id, tenant_id, namespace);


--
-- Name: idx_kv_version_expiry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_kv_version_expiry ON public.kv_version USING btree (expires_at_epoch_ms);


--
-- Name: idx_mdoc_vical_configuration_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mdoc_vical_configuration_tenant ON public.mdoc_vical_configuration USING btree (tenant_id);


--
-- Name: idx_ms_capability; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ms_capability ON public.metadata_snapshot USING btree (capability_id);


--
-- Name: idx_ms_software; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ms_software ON public.metadata_snapshot USING btree (software_party_id);


--
-- Name: idx_oauth_client_registration_list; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_oauth_client_registration_list ON public.oauth_client_registration USING btree (tenant_id, authorization_server_id, registered_at DESC);


--
-- Name: idx_oauth_signing_key_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_oauth_signing_key_active ON public.oauth_signing_key USING btree (tenant_id, priority DESC, created_at DESC) WHERE (state = 'ACTIVE'::text);


--
-- Name: idx_oauth_signing_key_publishable; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_oauth_signing_key_publishable ON public.oauth_signing_key USING btree (tenant_id, priority DESC, created_at DESC) WHERE (state <> 'DISABLED'::text);


--
-- Name: idx_oiasb_issuer_default_enabled_live; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_oiasb_issuer_default_enabled_live ON public.oid4vci_issuer_authorization_server_binding USING btree (tenant_id, issuer_capability_id) WHERE ((enabled = true) AND (is_default = true) AND (deleted_at IS NULL));


--
-- Name: idx_oiasb_issuer_enabled_order_live; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_oiasb_issuer_enabled_order_live ON public.oid4vci_issuer_authorization_server_binding USING btree (tenant_id, issuer_capability_id, enabled, display_order) WHERE (deleted_at IS NULL);


--
-- Name: idx_oiasb_issuer_server_live; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_oiasb_issuer_server_live ON public.oid4vci_issuer_authorization_server_binding USING btree (tenant_id, issuer_capability_id, authorization_server_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_oic_as; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_oic_as ON public.oid4vci_issuer_capability USING btree (authorization_server_capability_id);


--
-- Name: idx_oid4vci_offer_event_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_oid4vci_offer_event_lookup ON public.oid4vci_offer_session_event USING btree (tenant_id, instance_id, protocol_session_id, sequence);


--
-- Name: idx_oid4vci_offer_projection_aggregate; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_oid4vci_offer_projection_aggregate ON public.oid4vci_offer_session_projection USING btree (tenant_id, instance_id, current_state, updated_at);


--
-- Name: idx_oid4vci_offer_projection_list; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_oid4vci_offer_projection_list ON public.oid4vci_offer_session_projection USING btree (tenant_id, instance_id, created_at DESC, protocol_session_id);


--
-- Name: idx_oid4vp_auth_correlation; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_oid4vp_auth_correlation ON public.oid4vp_auth_session USING btree (correlation_id);


--
-- Name: idx_oid4vp_auth_oauth; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_oid4vp_auth_oauth ON public.oid4vp_auth_session USING btree (oauth_session_id) WHERE (oauth_session_id IS NOT NULL);


--
-- Name: idx_oid4vp_authorization_event_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_oid4vp_authorization_event_lookup ON public.oid4vp_authorization_session_event USING btree (tenant_id, instance_id, protocol_session_id, sequence);


--
-- Name: idx_oid4vp_authorization_projection_aggregate; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_oid4vp_authorization_projection_aggregate ON public.oid4vp_authorization_session_projection USING btree (tenant_id, instance_id, current_state, updated_at);


--
-- Name: idx_oid4vp_authorization_projection_list; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_oid4vp_authorization_projection_list ON public.oid4vp_authorization_session_projection USING btree (tenant_id, instance_id, created_at DESC, protocol_session_id);


--
-- Name: idx_oipp_issuer_live; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_oipp_issuer_live ON public.oid4vci_issuer_protocol_profile USING btree (tenant_id, issuer_capability_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_oopo_delivery_ready; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_oopo_delivery_ready ON public.oid4vci_override_projection_outbox USING btree (delivery_status, next_attempt_at, created_at);


--
-- Name: idx_opao_delivery_ready; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_opao_delivery_ready ON public.oid4vci_profile_audit_outbox USING btree (delivery_status, next_attempt_at, created_at);


--
-- Name: idx_organization_unit_parent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_organization_unit_parent ON public.organization_unit USING btree (parent_ou_id);


--
-- Name: idx_organization_unit_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_organization_unit_tenant ON public.organization_unit USING btree (tenant_id);


--
-- Name: idx_ovc_as; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ovc_as ON public.oid4vp_verifier_capability USING btree (authorization_server_capability_id);


--
-- Name: idx_party_external_relationship_external; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_party_external_relationship_external ON public.party_external_relationship USING btree (tenant_id, external_system, external_type, external_id, status);


--
-- Name: idx_party_external_relationship_party; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_party_external_relationship_party ON public.party_external_relationship USING btree (tenant_id, party_id, relationship_type, status);


--
-- Name: idx_party_external_relationship_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_party_external_relationship_source ON public.party_external_relationship USING btree (tenant_id, source_id);


--
-- Name: idx_party_organization_unit; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_party_organization_unit ON public.party USING btree (tenant_id, organization_unit_id);


--
-- Name: idx_party_owner; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_party_owner ON public.party USING btree (owner_id);


--
-- Name: idx_party_projection_relationship; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_party_projection_relationship ON public.party_relationship USING btree (tenant_id, left_party_id, right_party_id, relationship_type);


--
-- Name: idx_party_projection_tenant_uri; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_party_projection_tenant_uri ON public.party USING btree (tenant_id, uri) WHERE ((uri IS NOT NULL) AND (deleted_at IS NULL));


--
-- Name: idx_party_relationship_left; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_party_relationship_left ON public.party_relationship USING btree (left_party_id);


--
-- Name: idx_party_relationship_right; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_party_relationship_right ON public.party_relationship USING btree (right_party_id);


--
-- Name: idx_party_relationship_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_party_relationship_tenant ON public.party_relationship USING btree (tenant_id);


--
-- Name: idx_party_specialization_ou; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_party_specialization_ou ON public.party_specialization USING btree (tenant_id, organization_unit_id);


--
-- Name: idx_party_specialization_party; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_party_specialization_party ON public.party_specialization USING btree (party_id);


--
-- Name: idx_party_specialization_profile_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_party_specialization_profile_unique ON public.party_specialization USING btree (party_id, profile_id, COALESCE(organization_unit_id, ''::text)) WHERE (profile_id IS NOT NULL);


--
-- Name: idx_party_specialization_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_party_specialization_tenant ON public.party_specialization USING btree (tenant_id);


--
-- Name: idx_party_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_party_tenant ON public.party USING btree (tenant_id);


--
-- Name: idx_party_tenant_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_party_tenant_created ON public.party USING btree (tenant_id, created_at DESC);


--
-- Name: idx_party_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_party_type ON public.party USING btree (tenant_id, party_type);


--
-- Name: idx_physical_address_identifier; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_physical_address_identifier ON public.physical_address USING btree (identifier_id);


--
-- Name: idx_physical_address_party; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_physical_address_party ON public.physical_address USING btree (party_id);


--
-- Name: idx_quota_counter_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_quota_counter_lookup ON public.quota_counter USING btree (scope, scope_id, quota_key);


--
-- Name: idx_role_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_role_tenant ON public.role USING btree (tenant_id);


--
-- Name: idx_role_tenant_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_role_tenant_name ON public.role USING btree (tenant_id, name) WHERE (deleted_at IS NULL);


--
-- Name: idx_sc_party; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sc_party ON public.software_capability USING btree (party_id);


--
-- Name: idx_sc_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sc_status ON public.software_capability USING btree (tenant_id, lifecycle_status);


--
-- Name: idx_sc_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sc_type ON public.software_capability USING btree (tenant_id, capability_type);


--
-- Name: idx_scab_source_default_active; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_scab_source_default_active ON public.software_capability_binding USING btree (tenant_id, source_party_id, target_capability_type) WHERE ((is_default = true) AND (deleted_at IS NULL));


--
-- Name: idx_scab_source_target_active; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_scab_source_target_active ON public.software_capability_binding USING btree (tenant_id, source_party_id, target_party_id, target_capability_type) WHERE (deleted_at IS NULL);


--
-- Name: idx_scab_target_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_scab_target_active ON public.software_capability_binding USING btree (tenant_id, target_party_id, target_capability_type) WHERE (deleted_at IS NULL);


--
-- Name: idx_scb_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_scb_active ON public.software_config_binding USING btree (tenant_id, is_active);


--
-- Name: idx_scb_capability; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_scb_capability ON public.software_config_binding USING btree (capability_id);


--
-- Name: idx_scb_software; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_scb_software ON public.software_config_binding USING btree (software_party_id);


--
-- Name: idx_scb_tenant_prefix_active; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_scb_tenant_prefix_active ON public.software_config_binding USING btree (tenant_id, config_key_prefix) WHERE ((is_active = true) AND (deleted_at IS NULL));


--
-- Name: idx_schema_object_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_schema_object_tenant ON public.schema_object USING btree (tenant_id);


--
-- Name: idx_schema_object_tenant_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_schema_object_tenant_created ON public.schema_object USING btree (tenant_id, created_at DESC);


--
-- Name: idx_scred_capability; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_scred_capability ON public.software_credential USING btree (capability_id);


--
-- Name: idx_scred_software; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_scred_software ON public.software_credential USING btree (software_party_id);


--
-- Name: idx_sd_capability; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sd_capability ON public.software_deployment USING btree (capability_id);


--
-- Name: idx_sd_software; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sd_software ON public.software_deployment USING btree (software_party_id);


--
-- Name: idx_sd_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sd_status ON public.software_deployment USING btree (tenant_id, deployment_status);


--
-- Name: idx_se_capability; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_se_capability ON public.software_endpoint USING btree (capability_id);


--
-- Name: idx_se_software; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_se_software ON public.software_endpoint USING btree (software_party_id);


--
-- Name: idx_secret_kms_resource_mutation_resource; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_secret_kms_resource_mutation_resource ON public.secret_kms_resource_mutation USING btree (owner_tenant_id, resource_instance_key, created_at);


--
-- Name: idx_secret_permit_replay_expiry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_secret_permit_replay_expiry ON public.secret_permit_replay_state USING btree (expires_at);


--
-- Name: idx_secret_provider_cache_impact_revision; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_secret_provider_cache_impact_revision ON public.secret_provider_cache_impact USING btree (definition_id, revision, committed_at);


--
-- Name: idx_secret_resource_credential_binding_secret; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_secret_resource_credential_binding_secret ON public.secret_resource_credential_binding USING btree (secret_id, owner_tenant_id, secret_generation);


--
-- Name: idx_service_instance_quota_reservation_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_service_instance_quota_reservation_active ON public.service_instance_quota_reservation USING btree (tenant_id, service_type, status, expires_epoch_ms);


--
-- Name: idx_service_oauth_client_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_service_oauth_client_id ON public.service USING btree (tenant_id, oauth_client_id) WHERE (oauth_client_id IS NOT NULL);


--
-- Name: idx_service_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_service_tenant ON public.service USING btree (tenant_id);


--
-- Name: idx_session_expires; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_session_expires ON public.session USING btree (expires_at) WHERE (expires_at IS NOT NULL);


--
-- Name: idx_session_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_session_status ON public.session USING btree (tenant_id, status);


--
-- Name: idx_session_tenant_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_session_tenant_key ON public.session USING btree (tenant_id, session_type, session_key);


--
-- Name: idx_session_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_session_type ON public.session USING btree (tenant_id, session_type);


--
-- Name: idx_single_use_object_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_single_use_object_expires_at ON public.single_use_object USING btree (expires_at);


--
-- Name: idx_sp_kind; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sp_kind ON public.software_party USING btree (tenant_id, software_kind);


--
-- Name: idx_sp_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sp_tenant ON public.software_party USING btree (tenant_id);


--
-- Name: idx_subscription_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_subscription_status ON public.subscription USING btree (status, created_at) WHERE (deleted_at IS NULL);


--
-- Name: idx_subscription_tenant_active; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_subscription_tenant_active ON public.subscription USING btree (tenant_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_tenant_config_property_prefix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenant_config_property_prefix ON public.tenant_config_property USING btree (tenant_id, key);


--
-- Name: idx_tenant_domain_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenant_domain_tenant ON public.tenant_domain USING btree (tenant_id);


--
-- Name: idx_tenant_domain_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_tenant_domain_unique ON public.tenant_domain USING btree (domain) WHERE (deleted_at IS NULL);


--
-- Name: idx_tenant_kms_key_assignment_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenant_kms_key_assignment_key ON public.tenant_kms_key_assignment USING btree (tenant_id, provider_id, key_id, status);


--
-- Name: idx_tenant_kms_key_assignment_party; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenant_kms_key_assignment_party ON public.tenant_kms_key_assignment USING btree (tenant_id, party_id, status);


--
-- Name: idx_tenant_kms_key_assignment_service; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenant_kms_key_assignment_service ON public.tenant_kms_key_assignment USING btree (tenant_id, service_type, service_instance, purpose, status);


--
-- Name: idx_tenant_kms_key_metadata_lifecycle; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenant_kms_key_metadata_lifecycle ON public.tenant_kms_key_metadata USING btree (tenant_id, status, rotate_at, revoke_at);


--
-- Name: idx_tenant_kms_key_metadata_provider_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenant_kms_key_metadata_provider_status ON public.tenant_kms_key_metadata USING btree (tenant_id, provider_id, status);


--
-- Name: idx_tenant_kms_key_rotation_new_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenant_kms_key_rotation_new_provider ON public.tenant_kms_key_rotation USING btree (tenant_id, new_provider_id, status);


--
-- Name: idx_tenant_kms_key_rotation_old_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenant_kms_key_rotation_old_provider ON public.tenant_kms_key_rotation USING btree (tenant_id, old_provider_id, status);


--
-- Name: idx_tenant_kms_key_rotation_target_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenant_kms_key_rotation_target_provider ON public.tenant_kms_key_rotation USING btree (tenant_id, target_provider_id, status);


--
-- Name: idx_tenant_kms_provider_metadata_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenant_kms_provider_metadata_status ON public.tenant_kms_provider_metadata USING btree (tenant_id, status);


--
-- Name: idx_tenant_public_endpoint_active_default; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_tenant_public_endpoint_active_default ON public.tenant_public_endpoint USING btree (tenant_id, service_type) WHERE ((enabled = 1) AND (deleted_at IS NULL) AND (instance_id IS NULL));


--
-- Name: idx_tenant_public_endpoint_active_path; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_tenant_public_endpoint_active_path ON public.tenant_public_endpoint USING btree (host, path_prefix) WHERE ((enabled = 1) AND (deleted_at IS NULL) AND (host IS NOT NULL) AND (path_prefix IS NOT NULL));


--
-- Name: idx_tenant_public_endpoint_active_service; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_tenant_public_endpoint_active_service ON public.tenant_public_endpoint USING btree (tenant_id, service_type, instance_id) WHERE ((enabled = 1) AND (deleted_at IS NULL) AND (instance_id IS NOT NULL));


--
-- Name: idx_tenant_public_endpoint_active_well_known; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_tenant_public_endpoint_active_well_known ON public.tenant_public_endpoint USING btree (host, well_known_path) WHERE ((enabled = 1) AND (deleted_at IS NULL) AND (host IS NOT NULL) AND (well_known_path IS NOT NULL));


--
-- Name: idx_tenant_public_endpoint_service; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenant_public_endpoint_service ON public.tenant_public_endpoint USING btree (tenant_id, service_type);


--
-- Name: idx_tenant_public_endpoint_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenant_public_endpoint_tenant ON public.tenant_public_endpoint USING btree (tenant_id);


--
-- Name: idx_tenant_registration_log_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenant_registration_log_status ON public.tenant_registration_log USING btree (status, created_at);


--
-- Name: idx_tenant_registration_log_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenant_registration_log_tenant ON public.tenant_registration_log USING btree (tenant_id);


--
-- Name: idx_tenant_registration_step_log_log; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenant_registration_step_log_log ON public.tenant_registration_step_log USING btree (log_id, started_at);


--
-- Name: idx_tenant_routing_parent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenant_routing_parent ON public.tenant_routing USING btree (parent_tenant_id);


--
-- Name: idx_tenant_routing_slug_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_tenant_routing_slug_unique ON public.tenant_routing USING btree (slug) WHERE (deleted_at IS NULL);


--
-- Name: idx_tenant_signup_email_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_tenant_signup_email_slug ON public.tenant_signup_request USING btree (email, slug) WHERE (status = ANY (ARRAY['PENDING_EMAIL'::text, 'PENDING_APPROVAL'::text, 'CONFIRMED'::text]));


--
-- Name: idx_tenant_signup_expires; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenant_signup_expires ON public.tenant_signup_request USING btree (expires_at) WHERE (status = ANY (ARRAY['PENDING_EMAIL'::text, 'PENDING_APPROVAL'::text]));


--
-- Name: idx_tenant_signup_parent_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenant_signup_parent_status ON public.tenant_signup_request USING btree (parent_tenant_id, status, created_at);


--
-- Name: idx_tenant_user_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenant_user_tenant ON public.tenant_user USING btree (tenant_id);


--
-- Name: idx_tenant_user_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenant_user_user ON public.tenant_user USING btree (user_party_id);


--
-- Name: idx_terms_acceptance_version; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_terms_acceptance_version ON public.terms_acceptance USING btree (tenant_id, version);


--
-- Name: idx_theme_definition_slot; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_theme_definition_slot ON public.theme_definition USING btree (tenant_id, scope, product_type, application_id, variant) WHERE (deleted_at IS NULL);


--
-- Name: idx_theme_stylesheet_slot; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_theme_stylesheet_slot ON public.theme_stylesheet USING btree (tenant_id, COALESCE(application_id, ''::text));


--
-- Name: idx_transmission_claim; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_transmission_claim ON public.event_transmission USING btree (tenant_id, model_id, status, next_attempt_at, lease_expires_at);


--
-- Name: idx_transmission_claim_receiver; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_transmission_claim_receiver ON public.event_transmission USING btree (tenant_id, model_id, receiver_id, next_attempt_at);


--
-- Name: idx_transmission_status_retry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_transmission_status_retry ON public.event_transmission USING btree (status, retry_count);


--
-- Name: idx_transmission_tenant_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_transmission_tenant_created ON public.event_transmission USING btree (tenant_id, created_at DESC);


--
-- Name: idx_transmission_tenant_event; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_transmission_tenant_event ON public.event_transmission USING btree (tenant_id, event_id);


--
-- Name: idx_transmission_tenant_receiver; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_transmission_tenant_receiver ON public.event_transmission USING btree (tenant_id, receiver_id);


--
-- Name: idx_transmission_tenant_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_transmission_tenant_status ON public.event_transmission USING btree (tenant_id, status);


--
-- Name: idx_trust_anchor_admission_class; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trust_anchor_admission_class ON public.trust_anchor_admission USING btree (domain_id, admission_class, anchor_id);


--
-- Name: idx_trust_anchor_domain_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trust_anchor_domain_status ON public.trust_anchor USING btree (domain_id, status, valid_from, valid_until, anchor_id);


--
-- Name: idx_trust_anchor_identifier; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trust_anchor_identifier ON public.trust_anchor USING btree (identity_identifier_id);


--
-- Name: idx_trust_anchor_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trust_anchor_tenant ON public.trust_anchor USING btree (tenant_id);


--
-- Name: idx_trust_attachment_consumer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trust_attachment_consumer ON public.trust_attachment USING btree (consumer_kind, consumer_id, usage, attachment_id);


--
-- Name: idx_trust_attachment_domain_reverse; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trust_attachment_domain_reverse ON public.trust_attachment_domain USING btree (domain_id, attachment_id);


--
-- Name: idx_trust_attachment_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trust_attachment_tenant ON public.trust_attachment USING btree (tenant_id);


--
-- Name: idx_trust_catalog_domain_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trust_catalog_domain_status ON public.trust_catalog USING btree (domain_id, status, catalog_id);


--
-- Name: idx_trust_catalog_snapshot_freshness; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trust_catalog_snapshot_freshness ON public.trust_catalog_snapshot USING btree (catalog_row_key, valid_from, valid_until);


--
-- Name: idx_trust_catalog_snapshot_history; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trust_catalog_snapshot_history ON public.trust_catalog_snapshot USING btree (catalog_row_key, revision, snapshot_id);


--
-- Name: idx_trust_catalog_statement_authority_match; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trust_catalog_statement_authority_match ON public.trust_catalog_statement_authority USING btree (statement_row_key, framework_type, is_lote, authority_row_key);


--
-- Name: idx_trust_catalog_statement_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trust_catalog_statement_type ON public.trust_catalog_statement USING btree (snapshot_row_key, attestation_type_key, statement_row_key);


--
-- Name: idx_trust_catalog_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trust_catalog_tenant ON public.trust_catalog USING btree (tenant_id);


--
-- Name: idx_trust_domain_eligibility_domain_reverse; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trust_domain_eligibility_domain_reverse ON public.trust_domain_eligibility_domain USING btree (domain_id, grant_id);


--
-- Name: idx_trust_domain_eligibility_grant_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trust_domain_eligibility_grant_tenant ON public.trust_domain_eligibility_grant USING btree (tenant_id);


--
-- Name: idx_trust_domain_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trust_domain_status ON public.trust_domain USING btree (status, valid_from, valid_until, domain_id);


--
-- Name: idx_trust_domain_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trust_domain_tenant ON public.trust_domain USING btree (tenant_id);


--
-- Name: idx_trust_domain_v2_migration_issue_open; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trust_domain_v2_migration_issue_open ON public.trust_domain_v2_migration_issue USING btree (migration_id, blocking, remediation_status, reason_code);


--
-- Name: idx_trust_domain_v2_migration_work_state; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trust_domain_v2_migration_work_state ON public.trust_domain_v2_migration_work_item USING btree (migration_id, state, source_table, work_item_id);


--
-- Name: idx_trust_source_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trust_source_active ON public.trust_source USING btree (domain_id, enabled, active_revision, active_snapshot_id);


--
-- Name: idx_trust_source_derived_provenance; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trust_source_derived_provenance ON public.trust_source_derived_qeaa_entry USING btree (domain_id, source_id, revision, snapshot_id, provider_service_identity);


--
-- Name: idx_trust_source_refresh_history; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trust_source_refresh_history ON public.trust_source_refresh_attempt USING btree (domain_id, source_id, started_at);


--
-- Name: idx_trust_source_revision_history; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trust_source_revision_history ON public.trust_source_revision USING btree (domain_id, source_id, revision);


--
-- Name: idx_trust_source_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_trust_source_tenant ON public.trust_source USING btree (tenant_id);


--
-- Name: idx_user_credential_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_credential_identity ON public.user_credential USING btree (tenant_id, identity_id);


--
-- Name: idx_user_credential_locked_until; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_credential_locked_until ON public.user_credential USING btree (locked_until) WHERE (locked_until IS NOT NULL);


--
-- Name: idx_user_credential_username_hmac; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_user_credential_username_hmac ON public.user_credential USING btree (tenant_id, username_hmac);


--
-- Name: idx_user_party_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_party_email ON public.user_party USING btree (tenant_id, email);


--
-- Name: idx_user_party_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_party_tenant ON public.user_party USING btree (tenant_id);


--
-- Name: idx_user_party_tenant_username; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_user_party_tenant_username ON public.user_party USING btree (tenant_id, username) WHERE (deleted_at IS NULL);


--
-- Name: idx_user_party_username; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_party_username ON public.user_party USING btree (tenant_id, username);


--
-- Name: idx_user_role_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_role_role ON public.user_role USING btree (role_id);


--
-- Name: idx_user_role_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_role_tenant ON public.user_role USING btree (tenant_id);


--
-- Name: idx_user_role_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_role_user ON public.user_role USING btree (user_party_id);


--
-- Name: lote_draft_domain_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lote_draft_domain_idx ON public.lote_draft USING btree (tenant_id, domain_id);


--
-- Name: lote_published_lookup_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lote_published_lookup_idx ON public.lote_published_version USING btree (tenant_id, domain_id, lote_id, sequence_number);


--
-- Name: lote_remote_refresh_lookup_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lote_remote_refresh_lookup_idx ON public.lote_remote_refresh_attempt USING btree (tenant_id, domain_id, source_id, started_at);


--
-- Name: lote_remote_revision_lookup_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lote_remote_revision_lookup_idx ON public.lote_remote_revision USING btree (tenant_id, domain_id, source_id, revision);


--
-- Name: lote_remote_snapshot_lookup_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lote_remote_snapshot_lookup_idx ON public.lote_remote_snapshot USING btree (tenant_id, domain_id, source_id, snapshot_id);


--
-- Name: lote_remote_source_domain_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lote_remote_source_domain_idx ON public.lote_remote_source USING btree (tenant_id, domain_id, profile);


--
-- Name: policy_assignment_category_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX policy_assignment_category_idx ON public.policy_assignment USING btree (category_id);


--
-- Name: policy_assignment_group_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX policy_assignment_group_idx ON public.policy_assignment USING btree (group_id);


--
-- Name: policy_assignment_policy_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX policy_assignment_policy_idx ON public.policy_assignment USING btree (policy_id);


--
-- Name: policy_assignment_resource_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX policy_assignment_resource_idx ON public.policy_assignment USING btree (resource_id);


--
-- Name: policy_assignment_tenant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX policy_assignment_tenant_idx ON public.policy_assignment USING btree (tenant_id);


--
-- Name: requirement_category_slug_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX requirement_category_slug_idx ON public.requirement_category USING btree (tenant_id, slug) WHERE (deleted_at IS NULL);


--
-- Name: resource_category_slug_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resource_category_slug_idx ON public.resource_category USING btree (tenant_id, slug) WHERE (deleted_at IS NULL);


--
-- Name: resource_group_category_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resource_group_category_idx ON public.resource_group USING btree (category_id);


--
-- Name: resource_group_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resource_group_id_idx ON public.resource USING btree (resource_group_id);


--
-- Name: resource_group_tenant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX resource_group_tenant_idx ON public.resource_group USING btree (tenant_id);


--
-- Name: resource_requirement_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resource_requirement_unique ON public.resource_requirement USING btree (resource_id, credential_definition_id);


--
-- Name: resource_schedule_specific_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resource_schedule_specific_date_idx ON public.resource_schedule USING btree (resource_id, specific_date);


--
-- Name: resource_schedule_weekly_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX resource_schedule_weekly_idx ON public.resource_schedule USING btree (resource_id, day_of_week, valid_from);


--
-- Name: schedule_rule_day_of_week_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX schedule_rule_day_of_week_idx ON public.schedule_rule USING btree (schedule_set_id, day_of_week);


--
-- Name: schedule_rule_set_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX schedule_rule_set_idx ON public.schedule_rule USING btree (schedule_set_id);


--
-- Name: schedule_rule_specific_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX schedule_rule_specific_date_idx ON public.schedule_rule USING btree (schedule_set_id, specific_date);


--
-- Name: schedule_set_assignment_category_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX schedule_set_assignment_category_idx ON public.schedule_set_assignment USING btree (category_id);


--
-- Name: schedule_set_assignment_group_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX schedule_set_assignment_group_idx ON public.schedule_set_assignment USING btree (group_id);


--
-- Name: schedule_set_assignment_resource_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX schedule_set_assignment_resource_idx ON public.schedule_set_assignment USING btree (resource_id);


--
-- Name: schedule_set_assignment_schedule_set_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX schedule_set_assignment_schedule_set_idx ON public.schedule_set_assignment USING btree (schedule_set_id);


--
-- Name: schedule_set_assignment_tenant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX schedule_set_assignment_tenant_idx ON public.schedule_set_assignment USING btree (tenant_id);


--
-- Name: schedule_set_inclusion_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX schedule_set_inclusion_unique ON public.schedule_set_inclusion USING btree (parent_set_id, included_set_id);


--
-- Name: schedule_set_name_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX schedule_set_name_idx ON public.schedule_set USING btree (tenant_id, name) WHERE (deleted_at IS NULL);


--
-- Name: schedule_set_tenant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX schedule_set_tenant_idx ON public.schedule_set USING btree (tenant_id);


--
-- Name: uq_event_stream_sequence; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_event_stream_sequence ON public.event USING btree (tenant_id, model_id, stream_id, stream_sequence) WHERE (stream_id IS NOT NULL);


--
-- Name: uq_secret_authority_manifest_active; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_secret_authority_manifest_active ON public.secret_authority_manifest USING btree (authority_source) WHERE (lifecycle_state = 'ACTIVE'::text);


--
-- Name: uq_secret_credential_material_stage_non_terminal; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_secret_credential_material_stage_non_terminal ON public.secret_credential_material_stage USING btree (definition_id, revision) WHERE (operation_state <> ALL (ARRAY['COMMITTED'::text, 'FAILED'::text, 'CANCELLED'::text]));


--
-- Name: uq_secret_migration_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_secret_migration_idempotency ON public.secret_migration_journal USING btree (consumer_tenant_id, idempotency_key_hash);


--
-- Name: uq_secret_migration_non_terminal; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_secret_migration_non_terminal ON public.secret_migration_journal USING btree (COALESCE(consumer_tenant_id, '__platform__'::text)) WHERE (operation_state <> ALL (ARRAY['COMMITTED'::text, 'ROLLED_BACK'::text, 'PURGED'::text, 'FAILED'::text, 'CANCELLED'::text]));


--
-- Name: uq_secret_provider_assignment_active; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_secret_provider_assignment_active ON public.secret_provider_assignment USING btree (consumer_tenant_id, assignment_role) WHERE (lifecycle_state = 'ACTIVE'::text);


--
-- Name: uq_secret_resource_credential_binding_active; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_secret_resource_credential_binding_active ON public.secret_resource_credential_binding USING btree (owner_tenant_id, resource_kind, resource_instance_key, credential_slot) WHERE (lifecycle_state = 'ACTIVE'::text);


--
-- Name: uq_secret_rotation_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_secret_rotation_idempotency ON public.secret_credential_rotation_journal USING btree (definition_id, consumer_tenant_id, idempotency_key_hash);


--
-- Name: uq_secret_rotation_non_terminal; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_secret_rotation_non_terminal ON public.secret_credential_rotation_journal USING btree (definition_id, COALESCE(consumer_tenant_id, '__platform__'::text)) WHERE (operation_state <> ALL (ARRAY['COMMITTED'::text, 'ROLLED_BACK'::text, 'PURGED'::text, 'FAILED'::text, 'CANCELLED'::text]));


--
-- Name: uq_secret_value_mutation_non_terminal; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_secret_value_mutation_non_terminal ON public.secret_value_mutation_journal USING btree (consumer_tenant_id, secret_id) WHERE (mutation_phase <> ALL (ARRAY['COMMITTED'::text, 'PURGED'::text, 'FAILED'::text]));


--
-- Name: uq_system_credential_transition_non_terminal; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_system_credential_transition_non_terminal ON public.system_credential_transition USING btree (owner_tenant_id, workload_actor_id, purpose) WHERE (operation_phase = 'PREPARED'::text);


--
-- Name: uq_transmission_consumer_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_transmission_consumer_idempotency ON public.event_transmission USING btree (tenant_id, receiver_id, consumer_idempotency_key) WHERE (consumer_idempotency_key IS NOT NULL);


--
-- Name: uq_trust_source_eu_lotl_per_domain; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_trust_source_eu_lotl_per_domain ON public.trust_source USING btree (domain_id) WHERE (kind = 'ETSI_119612_EU_LOTL'::text);


--
-- Name: uq_trust_source_revision_single_active; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_trust_source_revision_single_active ON public.trust_source_revision USING btree (domain_id, source_id) WHERE (state = 'ACTIVE'::text);


--
-- Name: usage_policy_name_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX usage_policy_name_idx ON public.usage_policy USING btree (tenant_id, name) WHERE (deleted_at IS NULL);


--
-- Name: oauth_signing_key trg_oauth_signing_key_advance_revision; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_oauth_signing_key_advance_revision AFTER INSERT OR DELETE OR UPDATE ON public.oauth_signing_key FOR EACH ROW EXECUTE FUNCTION public.oauth_signing_key_advance_revision();


--
-- Name: oauth_signing_key trg_oauth_signing_key_advance_revision_on_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_oauth_signing_key_advance_revision_on_truncate AFTER TRUNCATE ON public.oauth_signing_key FOR EACH STATEMENT EXECUTE FUNCTION public.oauth_signing_key_advance_all_revisions();


--
-- Name: tenant_provider_binding trg_secret_management_assignment_count; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_assignment_count AFTER INSERT OR DELETE OR UPDATE ON public.tenant_provider_binding FOR EACH ROW EXECUTE FUNCTION public.secret_management_maintain_assignment_count();


--
-- Name: secret_provider_assignment trg_secret_management_assignment_eligibility; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_assignment_eligibility BEFORE INSERT OR UPDATE ON public.secret_provider_assignment FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_assignment_eligibility();


--
-- Name: secret_authority_grant trg_secret_management_authority_grant_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_authority_grant_guard BEFORE INSERT OR DELETE OR UPDATE ON public.secret_authority_grant FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_authority_grant();


--
-- Name: secret_authority_manifest trg_secret_management_authority_manifest_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_authority_manifest_guard BEFORE DELETE OR UPDATE ON public.secret_authority_manifest FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_authority_manifest();


--
-- Name: tenant_provider_binding trg_secret_management_binding_capability_exact; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER trg_secret_management_binding_capability_exact AFTER INSERT OR DELETE OR UPDATE ON public.tenant_provider_binding DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.secret_management_validate_current_tenant_capability();


--
-- Name: secret_provider_credential_binding trg_secret_management_binding_material_exact; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER trg_secret_management_binding_material_exact AFTER INSERT OR DELETE OR UPDATE ON public.secret_provider_credential_binding DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.secret_management_validate_current_credential_material();


--
-- Name: platform_bootstrap_credential trg_secret_management_bootstrap_generation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_bootstrap_generation AFTER INSERT OR UPDATE OF generation ON public.platform_bootstrap_credential FOR EACH ROW EXECUTE FUNCTION public.secret_management_record_bootstrap_generation();


--
-- Name: platform_bootstrap_credential_generation trg_secret_management_bootstrap_generation_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_bootstrap_generation_immutable BEFORE DELETE OR UPDATE ON public.platform_bootstrap_credential_generation FOR EACH ROW EXECUTE FUNCTION public.secret_management_generation_immutable();


--
-- Name: secret_provider_bootstrap_credential_material trg_secret_management_bootstrap_material_exact; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER trg_secret_management_bootstrap_material_exact AFTER INSERT OR DELETE OR UPDATE ON public.secret_provider_bootstrap_credential_material DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.secret_management_validate_current_credential_material();


--
-- Name: secret_provider_bootstrap_credential_material trg_secret_management_bootstrap_material_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_bootstrap_material_guard BEFORE INSERT OR DELETE OR UPDATE ON public.secret_provider_bootstrap_credential_material FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_credential_material();


--
-- Name: tenant_provider_capability_generation trg_secret_management_capability_binding_exact; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER trg_secret_management_capability_binding_exact AFTER INSERT OR DELETE OR UPDATE ON public.tenant_provider_capability_generation DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.secret_management_validate_current_tenant_capability();


--
-- Name: tenant_provider_capability_generation trg_secret_management_capability_generation_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_capability_generation_guard BEFORE INSERT OR DELETE OR UPDATE ON public.tenant_provider_capability_generation FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_capability_generation();


--
-- Name: tenant_provider_capability_material trg_secret_management_capability_material_binding_exact; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER trg_secret_management_capability_material_binding_exact AFTER INSERT OR DELETE OR UPDATE ON public.tenant_provider_capability_material DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.secret_management_validate_current_tenant_capability();


--
-- Name: tenant_provider_capability_material trg_secret_management_capability_material_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_capability_material_guard BEFORE INSERT OR DELETE OR UPDATE ON public.tenant_provider_capability_material FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_capability_material();


--
-- Name: secret_provider_environment_manifest_item trg_secret_management_config_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_config_immutable BEFORE INSERT OR DELETE OR UPDATE ON public.secret_provider_environment_manifest_item FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_configuration_mutation();


--
-- Name: secret_provider_kubernetes_mount_manifest_item trg_secret_management_config_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_config_immutable BEFORE INSERT OR DELETE OR UPDATE ON public.secret_provider_kubernetes_mount_manifest_item FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_configuration_mutation();


--
-- Name: secret_provider_revision_aws trg_secret_management_config_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_config_immutable BEFORE INSERT OR DELETE OR UPDATE ON public.secret_provider_revision_aws FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_configuration_mutation();


--
-- Name: secret_provider_revision_azure trg_secret_management_config_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_config_immutable BEFORE INSERT OR DELETE OR UPDATE ON public.secret_provider_revision_azure FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_configuration_mutation();


--
-- Name: secret_provider_revision_capability trg_secret_management_config_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_config_immutable BEFORE INSERT OR DELETE OR UPDATE ON public.secret_provider_revision_capability FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_configuration_mutation();


--
-- Name: secret_provider_revision_environment trg_secret_management_config_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_config_immutable BEFORE INSERT OR DELETE OR UPDATE ON public.secret_provider_revision_environment FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_configuration_mutation();


--
-- Name: secret_provider_revision_kms trg_secret_management_config_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_config_immutable BEFORE INSERT OR DELETE OR UPDATE ON public.secret_provider_revision_kms FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_configuration_mutation();


--
-- Name: secret_provider_revision_kms_authority_credential_slot trg_secret_management_config_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_config_immutable BEFORE INSERT OR DELETE OR UPDATE ON public.secret_provider_revision_kms_authority_credential_slot FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_configuration_mutation();


--
-- Name: secret_provider_revision_kms_authority_metadata trg_secret_management_config_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_config_immutable BEFORE INSERT OR DELETE OR UPDATE ON public.secret_provider_revision_kms_authority_metadata FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_configuration_mutation();


--
-- Name: secret_provider_revision_kms_operation_metadata trg_secret_management_config_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_config_immutable BEFORE INSERT OR DELETE OR UPDATE ON public.secret_provider_revision_kms_operation_metadata FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_configuration_mutation();


--
-- Name: secret_provider_revision_kubernetes_mount trg_secret_management_config_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_config_immutable BEFORE INSERT OR DELETE OR UPDATE ON public.secret_provider_revision_kubernetes_mount FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_configuration_mutation();


--
-- Name: secret_provider_revision_vault trg_secret_management_config_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_config_immutable BEFORE INSERT OR DELETE OR UPDATE ON public.secret_provider_revision_vault FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_configuration_mutation();


--
-- Name: secret_provider_credential_binding trg_secret_management_credential_binding_tier; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_credential_binding_tier BEFORE INSERT OR UPDATE ON public.secret_provider_credential_binding FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_credential_binding();


--
-- Name: secret_provider_definition trg_secret_management_definition_retirement; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_definition_retirement BEFORE UPDATE OF lifecycle_state ON public.secret_provider_definition FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_retirement_dependencies();


--
-- Name: platform_bootstrap_credential trg_secret_management_generation_advance; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_generation_advance BEFORE UPDATE ON public.platform_bootstrap_credential FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_generation_advance();


--
-- Name: secret_provider_credential_binding trg_secret_management_generation_advance; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_generation_advance BEFORE UPDATE ON public.secret_provider_credential_binding FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_generation_advance();


--
-- Name: secret_record trg_secret_management_generation_advance; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_generation_advance BEFORE UPDATE ON public.secret_record FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_generation_advance();


--
-- Name: tenant_provider_binding trg_secret_management_generation_advance; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_generation_advance BEFORE UPDATE ON public.tenant_provider_binding FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_generation_advance();


--
-- Name: global_tenant_secret_policy_provider_type trg_secret_management_global_policy_type_version; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_global_policy_type_version AFTER INSERT OR DELETE ON public.global_tenant_secret_policy_provider_type FOR EACH ROW EXECUTE FUNCTION public.secret_management_bump_policy_parent();


--
-- Name: global_tenant_secret_policy trg_secret_management_global_policy_version; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_global_policy_version AFTER INSERT OR UPDATE ON public.global_tenant_secret_policy FOR EACH ROW EXECUTE FUNCTION public.secret_management_sync_policy_collection_version();


--
-- Name: platform_secret_provider_offering trg_secret_management_guard_offering; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_guard_offering BEFORE INSERT OR UPDATE ON public.platform_secret_provider_offering FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_offering();


--
-- Name: secret_provider_revision trg_secret_management_guard_revision; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_guard_revision BEFORE INSERT OR UPDATE ON public.secret_provider_revision FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_revision();


--
-- Name: kms_secret_payload trg_secret_management_kms_payload_scope; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_kms_payload_scope BEFORE INSERT OR UPDATE ON public.kms_secret_payload FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_kms_payload_scope();


--
-- Name: secret_kms_resource_mutation trg_secret_management_kms_resource_mutation_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_kms_resource_mutation_immutable BEFORE DELETE OR UPDATE ON public.secret_kms_resource_mutation FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_kms_resource_mutation();


--
-- Name: secret_kms_resource_mutation_binding_result trg_secret_management_kms_resource_mutation_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_kms_resource_mutation_immutable BEFORE DELETE OR UPDATE ON public.secret_kms_resource_mutation_binding_result FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_kms_resource_mutation();


--
-- Name: secret_kms_resource_mutation_result trg_secret_management_kms_resource_mutation_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_kms_resource_mutation_immutable BEFORE DELETE OR UPDATE ON public.secret_kms_resource_mutation_result FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_kms_resource_mutation();


--
-- Name: platform_secret_provider_offering trg_secret_management_lifecycle; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_lifecycle BEFORE UPDATE OF lifecycle_state ON public.platform_secret_provider_offering FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_lifecycle_transition();


--
-- Name: secret_provider_assignment trg_secret_management_lifecycle; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_lifecycle BEFORE UPDATE OF lifecycle_state ON public.secret_provider_assignment FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_lifecycle_transition();


--
-- Name: secret_provider_definition trg_secret_management_lifecycle; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_lifecycle BEFORE UPDATE OF lifecycle_state ON public.secret_provider_definition FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_lifecycle_transition();


--
-- Name: secret_provider_revision trg_secret_management_lifecycle; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_lifecycle BEFORE UPDATE OF lifecycle_state ON public.secret_provider_revision FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_lifecycle_transition();


--
-- Name: secret_record trg_secret_management_lifecycle; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_lifecycle BEFORE UPDATE OF lifecycle_state ON public.secret_record FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_lifecycle_transition();


--
-- Name: tenant_provider_binding trg_secret_management_lifecycle; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_lifecycle BEFORE UPDATE OF lifecycle_state ON public.tenant_provider_binding FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_lifecycle_transition();


--
-- Name: secret_provider_platform_credential_material trg_secret_management_platform_material_exact; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER trg_secret_management_platform_material_exact AFTER INSERT OR DELETE OR UPDATE ON public.secret_provider_platform_credential_material DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.secret_management_validate_current_credential_material();


--
-- Name: secret_provider_platform_credential_material trg_secret_management_platform_material_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_platform_material_guard BEFORE INSERT OR DELETE OR UPDATE ON public.secret_provider_platform_credential_material FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_credential_material();


--
-- Name: tenant_provider_isolation_proof_aws trg_secret_management_proof_binding_exact; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER trg_secret_management_proof_binding_exact AFTER INSERT OR DELETE OR UPDATE ON public.tenant_provider_isolation_proof_aws DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.secret_management_validate_current_tenant_capability();


--
-- Name: tenant_provider_isolation_proof_azure trg_secret_management_proof_binding_exact; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER trg_secret_management_proof_binding_exact AFTER INSERT OR DELETE OR UPDATE ON public.tenant_provider_isolation_proof_azure DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.secret_management_validate_current_tenant_capability();


--
-- Name: tenant_provider_isolation_proof_kms trg_secret_management_proof_binding_exact; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER trg_secret_management_proof_binding_exact AFTER INSERT OR DELETE OR UPDATE ON public.tenant_provider_isolation_proof_kms DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.secret_management_validate_current_tenant_capability();


--
-- Name: tenant_provider_isolation_proof_vault trg_secret_management_proof_binding_exact; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER trg_secret_management_proof_binding_exact AFTER INSERT OR DELETE OR UPDATE ON public.tenant_provider_isolation_proof_vault DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.secret_management_validate_current_tenant_capability();


--
-- Name: tenant_provider_isolation_proof_aws trg_secret_management_proof_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_proof_immutable BEFORE INSERT OR DELETE OR UPDATE ON public.tenant_provider_isolation_proof_aws FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_isolation_proof();


--
-- Name: tenant_provider_isolation_proof_azure trg_secret_management_proof_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_proof_immutable BEFORE INSERT OR DELETE OR UPDATE ON public.tenant_provider_isolation_proof_azure FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_isolation_proof();


--
-- Name: tenant_provider_isolation_proof_kms trg_secret_management_proof_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_proof_immutable BEFORE INSERT OR DELETE OR UPDATE ON public.tenant_provider_isolation_proof_kms FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_isolation_proof();


--
-- Name: tenant_provider_isolation_proof_vault trg_secret_management_proof_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_proof_immutable BEFORE INSERT OR DELETE OR UPDATE ON public.tenant_provider_isolation_proof_vault FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_isolation_proof();


--
-- Name: secret_resource_credential_binding trg_secret_management_resource_binding_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_resource_binding_guard BEFORE DELETE OR UPDATE ON public.secret_resource_credential_binding FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_resource_binding();


--
-- Name: secret_provider_revision trg_secret_management_revision_retirement; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_revision_retirement BEFORE UPDATE OF lifecycle_state ON public.secret_provider_revision FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_retirement_dependencies();


--
-- Name: secret_record trg_secret_management_secret_generation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_secret_generation AFTER INSERT OR UPDATE OF generation ON public.secret_record FOR EACH ROW EXECUTE FUNCTION public.secret_management_record_secret_generation();


--
-- Name: secret_record_generation trg_secret_management_secret_generation_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_secret_generation_immutable BEFORE DELETE OR UPDATE ON public.secret_record_generation FOR EACH ROW EXECUTE FUNCTION public.secret_management_generation_immutable();


--
-- Name: secret_server_kms_resource_offering trg_secret_management_server_kms_resource_offering_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_server_kms_resource_offering_guard BEFORE INSERT OR DELETE OR UPDATE ON public.secret_server_kms_resource_offering FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_server_kms_resource_offering();


--
-- Name: secret_record trg_secret_management_system_credential_record; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_system_credential_record BEFORE INSERT OR DELETE OR UPDATE ON public.secret_record FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_system_credential_record();


--
-- Name: system_credential_reference trg_secret_management_system_credential_reference; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_system_credential_reference BEFORE INSERT OR DELETE OR UPDATE ON public.system_credential_reference FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_system_credential_reference();


--
-- Name: system_credential_transition trg_secret_management_system_credential_transition; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_system_credential_transition BEFORE INSERT OR DELETE OR UPDATE ON public.system_credential_transition FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_system_credential_transition();


--
-- Name: system_credential_transition_material trg_secret_management_system_credential_transition_material; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_system_credential_transition_material BEFORE INSERT OR DELETE OR UPDATE ON public.system_credential_transition_material FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_system_credential_transition_material();


--
-- Name: system_credential_use_binding trg_secret_management_system_credential_use_binding; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_system_credential_use_binding BEFORE INSERT OR DELETE OR UPDATE ON public.system_credential_use_binding FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_system_credential_use_binding();


--
-- Name: secret_collection_version trg_secret_management_tenant_collection_version; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_tenant_collection_version BEFORE UPDATE ON public.secret_collection_version FOR EACH ROW EXECUTE FUNCTION public.secret_management_guard_tenant_collection_version();


--
-- Name: tenant_secret_policy_override_provider_type trg_secret_management_tenant_policy_type_version; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_tenant_policy_type_version AFTER INSERT OR DELETE ON public.tenant_secret_policy_override_provider_type FOR EACH ROW EXECUTE FUNCTION public.secret_management_bump_policy_parent();


--
-- Name: tenant_secret_policy_override trg_secret_management_tenant_policy_version; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_tenant_policy_version AFTER INSERT OR DELETE OR UPDATE ON public.tenant_secret_policy_override FOR EACH ROW EXECUTE FUNCTION public.secret_management_sync_policy_collection_version();


--
-- Name: secret_provider_revision trg_secret_management_validate_ready; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_secret_management_validate_ready BEFORE UPDATE OF lifecycle_state ON public.secret_provider_revision FOR EACH ROW EXECUTE FUNCTION public.secret_management_validate_ready_revision();


--
-- Name: application_login_config application_login_config_application_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.application_login_config
    ADD CONSTRAINT application_login_config_application_id_fkey FOREIGN KEY (application_id) REFERENCES public.party(id) ON DELETE CASCADE;


--
-- Name: application_login_config application_login_config_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.application_login_config
    ADD CONSTRAINT application_login_config_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenant(id);


--
-- Name: authorization_server_hosted_configuration authorization_server_hosted_config_authorization_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authorization_server_hosted_configuration
    ADD CONSTRAINT authorization_server_hosted_config_authorization_server_id_fkey FOREIGN KEY (authorization_server_id) REFERENCES public.authorization_server_resource(id);


--
-- Name: authorization_server_hosted_signing authorization_server_hosted_signin_authorization_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authorization_server_hosted_signing
    ADD CONSTRAINT authorization_server_hosted_signin_authorization_server_id_fkey FOREIGN KEY (authorization_server_id) REFERENCES public.authorization_server_resource(id);


--
-- Name: booking_metadata booking_metadata_booking_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_metadata
    ADD CONSTRAINT booking_metadata_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES public.booking(id) ON DELETE CASCADE;


--
-- Name: booking booking_resource_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking
    ADD CONSTRAINT booking_resource_id_fkey FOREIGN KEY (resource_id) REFERENCES public.resource(party_id) ON DELETE CASCADE;


--
-- Name: booking_verification booking_verification_booking_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_verification
    ADD CONSTRAINT booking_verification_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES public.booking(id) ON DELETE CASCADE;


--
-- Name: booking_verification booking_verification_requirement_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.booking_verification
    ADD CONSTRAINT booking_verification_requirement_id_fkey FOREIGN KEY (requirement_id) REFERENCES public.resource_requirement(id) ON DELETE CASCADE;


--
-- Name: did_also_known_as did_also_known_as_did_record_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.did_also_known_as
    ADD CONSTRAINT did_also_known_as_did_record_id_fkey FOREIGN KEY (did_record_id) REFERENCES public.did_record(id) ON DELETE CASCADE;


--
-- Name: did_controller did_controller_did_record_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.did_controller
    ADD CONSTRAINT did_controller_did_record_id_fkey FOREIGN KEY (did_record_id) REFERENCES public.did_record(id) ON DELETE CASCADE;


--
-- Name: did_document_context did_document_context_did_record_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.did_document_context
    ADD CONSTRAINT did_document_context_did_record_id_fkey FOREIGN KEY (did_record_id) REFERENCES public.did_record(id) ON DELETE CASCADE;


--
-- Name: did_equivalent_id did_equivalent_id_did_record_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.did_equivalent_id
    ADD CONSTRAINT did_equivalent_id_did_record_id_fkey FOREIGN KEY (did_record_id) REFERENCES public.did_record(id) ON DELETE CASCADE;


--
-- Name: did_key_mapping did_key_mapping_did_record_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.did_key_mapping
    ADD CONSTRAINT did_key_mapping_did_record_id_fkey FOREIGN KEY (did_record_id) REFERENCES public.did_record(id) ON DELETE CASCADE;


--
-- Name: did_key_mapping did_key_mapping_verification_method_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.did_key_mapping
    ADD CONSTRAINT did_key_mapping_verification_method_id_fkey FOREIGN KEY (verification_method_id) REFERENCES public.did_verification_method(id) ON DELETE CASCADE;


--
-- Name: did_service did_service_did_record_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.did_service
    ADD CONSTRAINT did_service_did_record_id_fkey FOREIGN KEY (did_record_id) REFERENCES public.did_record(id) ON DELETE CASCADE;


--
-- Name: did_verification_method did_verification_method_did_record_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.did_verification_method
    ADD CONSTRAINT did_verification_method_did_record_id_fkey FOREIGN KEY (did_record_id) REFERENCES public.did_record(id) ON DELETE CASCADE;


--
-- Name: did_verification_relationship did_verification_relationship_did_record_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.did_verification_relationship
    ADD CONSTRAINT did_verification_relationship_did_record_id_fkey FOREIGN KEY (did_record_id) REFERENCES public.did_record(id) ON DELETE CASCADE;


--
-- Name: did_verification_relationship did_verification_relationship_entry_embedded_vm_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.did_verification_relationship
    ADD CONSTRAINT did_verification_relationship_entry_embedded_vm_id_fkey FOREIGN KEY (entry_embedded_vm_id) REFERENCES public.did_verification_method(id) ON DELETE CASCADE;


--
-- Name: app_party fk_app_party_software; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_party
    ADD CONSTRAINT fk_app_party_software FOREIGN KEY (party_id) REFERENCES public.software_party(party_id) ON DELETE CASCADE;


--
-- Name: authorization_server_federation_binding fk_asfb_external; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authorization_server_federation_binding
    ADD CONSTRAINT fk_asfb_external FOREIGN KEY (external_authorization_server_id) REFERENCES public.authorization_server_resource(id);


--
-- Name: authorization_server_federation_binding fk_asfb_hosted; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authorization_server_federation_binding
    ADD CONSTRAINT fk_asfb_hosted FOREIGN KEY (hosted_authorization_server_id) REFERENCES public.authorization_server_resource(id);


--
-- Name: authorization_server_migration_ledger fk_asml_target; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authorization_server_migration_ledger
    ADD CONSTRAINT fk_asml_target FOREIGN KEY (target_authorization_server_id) REFERENCES public.authorization_server_resource(id);


--
-- Name: authorization_server_migration_source_change fk_asmlsc_ledger; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authorization_server_migration_source_change
    ADD CONSTRAINT fk_asmlsc_ledger FOREIGN KEY (ledger_id) REFERENCES public.authorization_server_migration_ledger(id);


--
-- Name: authorization_server_resource fk_asr_capability; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authorization_server_resource
    ADD CONSTRAINT fk_asr_capability FOREIGN KEY (authorization_server_capability_id) REFERENCES public.oauth2_as_capability(capability_id);


--
-- Name: business_wallet_membership fk_bwm_wallet; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_wallet_membership
    ADD CONSTRAINT fk_bwm_wallet FOREIGN KEY (wallet_party_id) REFERENCES public.software_party(party_id) ON DELETE CASCADE;


--
-- Name: credential_actor_credential_definitions fk_cacd_ca; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credential_actor_credential_definitions
    ADD CONSTRAINT fk_cacd_ca FOREIGN KEY (party_id) REFERENCES public.credential_actor(party_id) ON DELETE CASCADE;


--
-- Name: credential_actor_credential_definitions fk_cacd_cd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credential_actor_credential_definitions
    ADD CONSTRAINT fk_cacd_cd FOREIGN KEY (credential_definition_id) REFERENCES public.credential_definition(id) ON DELETE CASCADE;


--
-- Name: connector_capability_detail fk_connector_cap; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.connector_capability_detail
    ADD CONSTRAINT fk_connector_cap FOREIGN KEY (capability_id) REFERENCES public.software_capability(id) ON DELETE CASCADE;


--
-- Name: credential_actor fk_credential_actor_party; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credential_actor
    ADD CONSTRAINT fk_credential_actor_party FOREIGN KEY (party_id) REFERENCES public.party(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: credential_definition fk_credential_definition_credential_template_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credential_definition
    ADD CONSTRAINT fk_credential_definition_credential_template_id FOREIGN KEY (credential_template_id) REFERENCES public.credential_template(party_id) ON DELETE CASCADE;


--
-- Name: credential_template_claim fk_credential_template; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credential_template_claim
    ADD CONSTRAINT fk_credential_template FOREIGN KEY (credential_template_id) REFERENCES public.credential_template(party_id) ON DELETE CASCADE;


--
-- Name: credential_template_claim_display fk_credential_template_claim_display_claim_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credential_template_claim_display
    ADD CONSTRAINT fk_credential_template_claim_display_claim_id FOREIGN KEY (credential_template_claim_id) REFERENCES public.credential_template_claim(id) ON DELETE CASCADE;


--
-- Name: credential_templates_schemas fk_cts_credential_template; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credential_templates_schemas
    ADD CONSTRAINT fk_cts_credential_template FOREIGN KEY (party_id) REFERENCES public.credential_template(party_id) ON DELETE CASCADE;


--
-- Name: credential_templates_schemas fk_cts_schema_object; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credential_templates_schemas
    ADD CONSTRAINT fk_cts_schema_object FOREIGN KEY (schema_id) REFERENCES public.schema_object(id) ON DELETE CASCADE;


--
-- Name: electronic_address fk_electronic_address_party; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.electronic_address
    ADD CONSTRAINT fk_electronic_address_party FOREIGN KEY (party_id) REFERENCES public.party(id) ON DELETE CASCADE;


--
-- Name: group_party fk_group_party_party; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_party
    ADD CONSTRAINT fk_group_party_party FOREIGN KEY (party_id) REFERENCES public.party(id) ON DELETE CASCADE;


--
-- Name: issuer fk_issuer_credential_actor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issuer
    ADD CONSTRAINT fk_issuer_credential_actor FOREIGN KEY (party_id) REFERENCES public.credential_actor(party_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: issuer_credential_definition fk_issuer_credential_definition_credential_definition_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.issuer_credential_definition
    ADD CONSTRAINT fk_issuer_credential_definition_credential_definition_id FOREIGN KEY (credential_definition_id) REFERENCES public.credential_definition(id) ON DELETE CASCADE;


--
-- Name: kv_version_link fk_kv_version_link_child; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.kv_version_link
    ADD CONSTRAINT fk_kv_version_link_child FOREIGN KEY (stream_id, version_id) REFERENCES public.kv_version(stream_id, id);


--
-- Name: kv_version_link fk_kv_version_link_parent; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.kv_version_link
    ADD CONSTRAINT fk_kv_version_link_parent FOREIGN KEY (stream_id, previous_version_id) REFERENCES public.kv_version(stream_id, id);


--
-- Name: metadata_snapshot fk_ms_capability; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.metadata_snapshot
    ADD CONSTRAINT fk_ms_capability FOREIGN KEY (capability_id) REFERENCES public.software_capability(id);


--
-- Name: metadata_snapshot fk_ms_software; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.metadata_snapshot
    ADD CONSTRAINT fk_ms_software FOREIGN KEY (software_party_id) REFERENCES public.software_party(party_id) ON DELETE CASCADE;


--
-- Name: natural_person fk_natural_person_party; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.natural_person
    ADD CONSTRAINT fk_natural_person_party FOREIGN KEY (party_id) REFERENCES public.party(id) ON DELETE CASCADE;


--
-- Name: oid4vci_authorization_server_override fk_oaso_authorization_server; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vci_authorization_server_override
    ADD CONSTRAINT fk_oaso_authorization_server FOREIGN KEY (authorization_server_id) REFERENCES public.authorization_server_resource(id);


--
-- Name: oid4vci_authorization_server_override fk_oaso_issuer; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vci_authorization_server_override
    ADD CONSTRAINT fk_oaso_issuer FOREIGN KEY (issuer_capability_id) REFERENCES public.oid4vci_issuer_capability(capability_id);


--
-- Name: oauth2_as_capability fk_oauth2_as_cap; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth2_as_capability
    ADD CONSTRAINT fk_oauth2_as_cap FOREIGN KEY (capability_id) REFERENCES public.software_capability(id) ON DELETE CASCADE;


--
-- Name: oid4vci_issuer_authorization_server_binding fk_oiasb_authorization_server; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vci_issuer_authorization_server_binding
    ADD CONSTRAINT fk_oiasb_authorization_server FOREIGN KEY (authorization_server_id) REFERENCES public.authorization_server_resource(id);


--
-- Name: oid4vci_issuer_authorization_server_binding fk_oiasb_issuer; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vci_issuer_authorization_server_binding
    ADD CONSTRAINT fk_oiasb_issuer FOREIGN KEY (issuer_capability_id) REFERENCES public.oid4vci_issuer_capability(capability_id);


--
-- Name: oid4vci_issuer_capability fk_oid4vci_cap; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vci_issuer_capability
    ADD CONSTRAINT fk_oid4vci_cap FOREIGN KEY (capability_id) REFERENCES public.software_capability(id) ON DELETE CASCADE;


--
-- Name: oid4vci_issuer_capability fk_oid4vci_cap_as; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vci_issuer_capability
    ADD CONSTRAINT fk_oid4vci_cap_as FOREIGN KEY (authorization_server_capability_id) REFERENCES public.oauth2_as_capability(capability_id);


--
-- Name: oid4vci_issuer fk_oid4vci_issuer_issuer; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vci_issuer
    ADD CONSTRAINT fk_oid4vci_issuer_issuer FOREIGN KEY (party_id) REFERENCES public.issuer(party_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: oid4vp_verifier_capability fk_oid4vp_cap; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vp_verifier_capability
    ADD CONSTRAINT fk_oid4vp_cap FOREIGN KEY (capability_id) REFERENCES public.software_capability(id) ON DELETE CASCADE;


--
-- Name: oid4vp_verifier_capability fk_oid4vp_cap_as; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vp_verifier_capability
    ADD CONSTRAINT fk_oid4vp_cap_as FOREIGN KEY (authorization_server_capability_id) REFERENCES public.oauth2_as_capability(capability_id);


--
-- Name: oid4vp_verifier fk_oid4vp_verifier_verifier; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vp_verifier
    ADD CONSTRAINT fk_oid4vp_verifier_verifier FOREIGN KEY (party_id) REFERENCES public.verifier(party_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: oid4vci_issuer_protocol_profile fk_oipp_issuer; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vci_issuer_protocol_profile
    ADD CONSTRAINT fk_oipp_issuer FOREIGN KEY (issuer_capability_id) REFERENCES public.oid4vci_issuer_capability(capability_id);


--
-- Name: oid4vci_override_projection_outbox fk_oopo_issuer; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vci_override_projection_outbox
    ADD CONSTRAINT fk_oopo_issuer FOREIGN KEY (issuer_capability_id) REFERENCES public.oid4vci_issuer_capability(capability_id);


--
-- Name: oid4vci_override_projection_outbox fk_oopo_override; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vci_override_projection_outbox
    ADD CONSTRAINT fk_oopo_override FOREIGN KEY (override_id) REFERENCES public.oid4vci_authorization_server_override(id);


--
-- Name: oid4vci_profile_audit_outbox fk_opao_issuer; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vci_profile_audit_outbox
    ADD CONSTRAINT fk_opao_issuer FOREIGN KEY (issuer_capability_id) REFERENCES public.oid4vci_issuer_capability(capability_id);


--
-- Name: organization fk_organization_party; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization
    ADD CONSTRAINT fk_organization_party FOREIGN KEY (party_id) REFERENCES public.party(id) ON DELETE CASCADE;


--
-- Name: party_relationship fk_party_relationship_left_party; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.party_relationship
    ADD CONSTRAINT fk_party_relationship_left_party FOREIGN KEY (left_party_id) REFERENCES public.party(id);


--
-- Name: party_relationship fk_party_relationship_right_party; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.party_relationship
    ADD CONSTRAINT fk_party_relationship_right_party FOREIGN KEY (right_party_id) REFERENCES public.party(id);


--
-- Name: resource fk_resource_party; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource
    ADD CONSTRAINT fk_resource_party FOREIGN KEY (party_id) REFERENCES public.party(id) ON DELETE CASCADE;


--
-- Name: software_assignment fk_sa_assignee; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.software_assignment
    ADD CONSTRAINT fk_sa_assignee FOREIGN KEY (assignee_party_id) REFERENCES public.party(id);


--
-- Name: software_assignment fk_sa_software; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.software_assignment
    ADD CONSTRAINT fk_sa_software FOREIGN KEY (software_party_id) REFERENCES public.software_party(party_id);


--
-- Name: software_capability fk_sc_party; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.software_capability
    ADD CONSTRAINT fk_sc_party FOREIGN KEY (party_id) REFERENCES public.party(id) ON DELETE CASCADE;


--
-- Name: software_capability_binding fk_scab_source; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.software_capability_binding
    ADD CONSTRAINT fk_scab_source FOREIGN KEY (source_party_id) REFERENCES public.software_party(party_id) ON DELETE CASCADE;


--
-- Name: software_capability_binding fk_scab_target; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.software_capability_binding
    ADD CONSTRAINT fk_scab_target FOREIGN KEY (target_party_id) REFERENCES public.software_party(party_id) ON DELETE CASCADE;


--
-- Name: software_config_binding fk_scb_capability; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.software_config_binding
    ADD CONSTRAINT fk_scb_capability FOREIGN KEY (capability_id) REFERENCES public.software_capability(id);


--
-- Name: software_config_binding fk_scb_deployment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.software_config_binding
    ADD CONSTRAINT fk_scb_deployment FOREIGN KEY (deployment_id) REFERENCES public.software_deployment(id);


--
-- Name: software_config_binding fk_scb_software; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.software_config_binding
    ADD CONSTRAINT fk_scb_software FOREIGN KEY (software_party_id) REFERENCES public.software_party(party_id) ON DELETE CASCADE;


--
-- Name: schema_object fk_schema_object_created_by; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_object
    ADD CONSTRAINT fk_schema_object_created_by FOREIGN KEY (created_by_id) REFERENCES public.party(id) ON DELETE SET NULL;


--
-- Name: schema_object fk_schema_object_owner; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_object
    ADD CONSTRAINT fk_schema_object_owner FOREIGN KEY (owner_id) REFERENCES public.party(id) ON DELETE SET NULL;


--
-- Name: schema_object fk_schema_object_tenant; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_object
    ADD CONSTRAINT fk_schema_object_tenant FOREIGN KEY (tenant_id) REFERENCES public.tenant(id) ON DELETE CASCADE;


--
-- Name: software_credential fk_scred_capability; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.software_credential
    ADD CONSTRAINT fk_scred_capability FOREIGN KEY (capability_id) REFERENCES public.software_capability(id);


--
-- Name: software_credential fk_scred_software; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.software_credential
    ADD CONSTRAINT fk_scred_software FOREIGN KEY (software_party_id) REFERENCES public.software_party(party_id) ON DELETE CASCADE;


--
-- Name: software_deployment fk_sd_capability; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.software_deployment
    ADD CONSTRAINT fk_sd_capability FOREIGN KEY (capability_id) REFERENCES public.software_capability(id);


--
-- Name: software_deployment fk_sd_software; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.software_deployment
    ADD CONSTRAINT fk_sd_software FOREIGN KEY (software_party_id) REFERENCES public.software_party(party_id) ON DELETE CASCADE;


--
-- Name: software_endpoint fk_se_capability; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.software_endpoint
    ADD CONSTRAINT fk_se_capability FOREIGN KEY (capability_id) REFERENCES public.software_capability(id);


--
-- Name: software_endpoint fk_se_deployment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.software_endpoint
    ADD CONSTRAINT fk_se_deployment FOREIGN KEY (deployment_id) REFERENCES public.software_deployment(id);


--
-- Name: software_endpoint fk_se_software; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.software_endpoint
    ADD CONSTRAINT fk_se_software FOREIGN KEY (software_party_id) REFERENCES public.software_party(party_id) ON DELETE CASCADE;


--
-- Name: server_party fk_server_party_operator; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.server_party
    ADD CONSTRAINT fk_server_party_operator FOREIGN KEY (operator_party_id) REFERENCES public.party(id);


--
-- Name: server_party fk_server_party_software; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.server_party
    ADD CONSTRAINT fk_server_party_software FOREIGN KEY (party_id) REFERENCES public.software_party(party_id) ON DELETE CASCADE;


--
-- Name: software_party fk_software_party_party; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.software_party
    ADD CONSTRAINT fk_software_party_party FOREIGN KEY (party_id) REFERENCES public.party(id) ON DELETE CASCADE;


--
-- Name: software_party fk_software_party_vendor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.software_party
    ADD CONSTRAINT fk_software_party_vendor FOREIGN KEY (vendor_party_id) REFERENCES public.party(id);


--
-- Name: trust_anchor_admission fk_trust_anchor_admission_anchor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_anchor_admission
    ADD CONSTRAINT fk_trust_anchor_admission_anchor FOREIGN KEY (domain_id, anchor_id) REFERENCES public.trust_anchor(domain_id, anchor_id) ON DELETE CASCADE;


--
-- Name: trust_anchor fk_trust_anchor_domain; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_anchor
    ADD CONSTRAINT fk_trust_anchor_domain FOREIGN KEY (domain_id) REFERENCES public.trust_domain(domain_id) ON DELETE CASCADE;


--
-- Name: trust_attachment_domain fk_trust_attachment_domain_attachment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_attachment_domain
    ADD CONSTRAINT fk_trust_attachment_domain_attachment FOREIGN KEY (attachment_id) REFERENCES public.trust_attachment(attachment_id) ON DELETE CASCADE;


--
-- Name: trust_attachment_domain fk_trust_attachment_domain_domain; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_attachment_domain
    ADD CONSTRAINT fk_trust_attachment_domain_domain FOREIGN KEY (domain_id) REFERENCES public.trust_domain(domain_id) ON DELETE RESTRICT;


--
-- Name: trust_catalog fk_trust_catalog_domain; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog
    ADD CONSTRAINT fk_trust_catalog_domain FOREIGN KEY (domain_id) REFERENCES public.trust_domain(domain_id) ON DELETE CASCADE;


--
-- Name: trust_catalog_snapshot_artifact fk_trust_catalog_snapshot_artifact_snapshot; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_snapshot_artifact
    ADD CONSTRAINT fk_trust_catalog_snapshot_artifact_snapshot FOREIGN KEY (snapshot_row_key) REFERENCES public.trust_catalog_snapshot(snapshot_row_key) ON DELETE CASCADE;


--
-- Name: trust_catalog_snapshot fk_trust_catalog_snapshot_catalog; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_snapshot
    ADD CONSTRAINT fk_trust_catalog_snapshot_catalog FOREIGN KEY (catalog_row_key) REFERENCES public.trust_catalog(catalog_row_key) ON DELETE CASCADE;


--
-- Name: trust_catalog_snapshot_provenance fk_trust_catalog_snapshot_provenance_artifact; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_snapshot_provenance
    ADD CONSTRAINT fk_trust_catalog_snapshot_provenance_artifact FOREIGN KEY (snapshot_row_key, source_artifact_role) REFERENCES public.trust_catalog_snapshot_artifact(snapshot_row_key, artifact_role) ON DELETE RESTRICT;


--
-- Name: trust_catalog_snapshot_provenance fk_trust_catalog_snapshot_provenance_snapshot; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_snapshot_provenance
    ADD CONSTRAINT fk_trust_catalog_snapshot_provenance_snapshot FOREIGN KEY (snapshot_row_key) REFERENCES public.trust_catalog_snapshot(snapshot_row_key) ON DELETE CASCADE;


--
-- Name: trust_catalog_snapshot_publication fk_trust_catalog_snapshot_publication_artifact; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_snapshot_publication
    ADD CONSTRAINT fk_trust_catalog_snapshot_publication_artifact FOREIGN KEY (snapshot_row_key, publication_artifact_role) REFERENCES public.trust_catalog_snapshot_artifact(snapshot_row_key, artifact_role) ON DELETE RESTRICT;


--
-- Name: trust_catalog_snapshot_publication fk_trust_catalog_snapshot_publication_snapshot; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_snapshot_publication
    ADD CONSTRAINT fk_trust_catalog_snapshot_publication_snapshot FOREIGN KEY (snapshot_row_key) REFERENCES public.trust_catalog_snapshot(snapshot_row_key) ON DELETE CASCADE;


--
-- Name: trust_catalog_snapshot_signature fk_trust_catalog_snapshot_signature_snapshot; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_snapshot_signature
    ADD CONSTRAINT fk_trust_catalog_snapshot_signature_snapshot FOREIGN KEY (snapshot_row_key) REFERENCES public.trust_catalog_snapshot(snapshot_row_key) ON DELETE CASCADE;


--
-- Name: trust_catalog_snapshot_validation fk_trust_catalog_snapshot_validation_snapshot; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_snapshot_validation
    ADD CONSTRAINT fk_trust_catalog_snapshot_validation_snapshot FOREIGN KEY (snapshot_row_key) REFERENCES public.trust_catalog_snapshot(snapshot_row_key) ON DELETE CASCADE;


--
-- Name: trust_catalog_statement_authority fk_trust_catalog_statement_authority_statement; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_statement_authority
    ADD CONSTRAINT fk_trust_catalog_statement_authority_statement FOREIGN KEY (statement_row_key) REFERENCES public.trust_catalog_statement(statement_row_key) ON DELETE CASCADE;


--
-- Name: trust_catalog_statement_format fk_trust_catalog_statement_format_statement; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_statement_format
    ADD CONSTRAINT fk_trust_catalog_statement_format_statement FOREIGN KEY (statement_row_key) REFERENCES public.trust_catalog_statement(statement_row_key) ON DELETE CASCADE;


--
-- Name: trust_catalog_statement_schema_uri fk_trust_catalog_statement_schema_uri_statement; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_statement_schema_uri
    ADD CONSTRAINT fk_trust_catalog_statement_schema_uri_statement FOREIGN KEY (statement_row_key) REFERENCES public.trust_catalog_statement(statement_row_key) ON DELETE CASCADE;


--
-- Name: trust_catalog_statement fk_trust_catalog_statement_snapshot; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_catalog_statement
    ADD CONSTRAINT fk_trust_catalog_statement_snapshot FOREIGN KEY (snapshot_row_key) REFERENCES public.trust_catalog_snapshot(snapshot_row_key) ON DELETE CASCADE;


--
-- Name: trust_domain_eligibility_domain fk_trust_domain_eligibility_domain_domain; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_domain_eligibility_domain
    ADD CONSTRAINT fk_trust_domain_eligibility_domain_domain FOREIGN KEY (domain_id) REFERENCES public.trust_domain(domain_id) ON DELETE RESTRICT;


--
-- Name: trust_domain_eligibility_domain fk_trust_domain_eligibility_domain_grant; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_domain_eligibility_domain
    ADD CONSTRAINT fk_trust_domain_eligibility_domain_grant FOREIGN KEY (grant_id) REFERENCES public.trust_domain_eligibility_grant(grant_id) ON DELETE CASCADE;


--
-- Name: trust_domain_v2_migration_issue fk_trust_domain_v2_migration_issue_migration; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_domain_v2_migration_issue
    ADD CONSTRAINT fk_trust_domain_v2_migration_issue_migration FOREIGN KEY (migration_id) REFERENCES public.trust_domain_v2_migration(migration_id) ON DELETE RESTRICT;


--
-- Name: trust_domain_v2_migration_issue fk_trust_domain_v2_migration_issue_work; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_domain_v2_migration_issue
    ADD CONSTRAINT fk_trust_domain_v2_migration_issue_work FOREIGN KEY (migration_id, work_item_id) REFERENCES public.trust_domain_v2_migration_work_item(migration_id, work_item_id) ON DELETE RESTRICT;


--
-- Name: trust_domain_v2_migration_stage fk_trust_domain_v2_migration_stage_migration; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_domain_v2_migration_stage
    ADD CONSTRAINT fk_trust_domain_v2_migration_stage_migration FOREIGN KEY (migration_id) REFERENCES public.trust_domain_v2_migration(migration_id) ON DELETE RESTRICT;


--
-- Name: trust_domain_v2_migration_work_item fk_trust_domain_v2_migration_work_migration; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_domain_v2_migration_work_item
    ADD CONSTRAINT fk_trust_domain_v2_migration_work_migration FOREIGN KEY (migration_id) REFERENCES public.trust_domain_v2_migration(migration_id) ON DELETE RESTRICT;


--
-- Name: trust_source_derived_qeaa_entry fk_trust_source_derived_snapshot; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_source_derived_qeaa_entry
    ADD CONSTRAINT fk_trust_source_derived_snapshot FOREIGN KEY (domain_id, source_id, revision, snapshot_id) REFERENCES public.trust_source_snapshot(domain_id, source_id, revision, snapshot_id) ON DELETE CASCADE;


--
-- Name: trust_source fk_trust_source_domain; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_source
    ADD CONSTRAINT fk_trust_source_domain FOREIGN KEY (domain_id) REFERENCES public.trust_domain(domain_id) ON DELETE CASCADE;


--
-- Name: trust_source_refresh_attempt fk_trust_source_refresh_revision; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_source_refresh_attempt
    ADD CONSTRAINT fk_trust_source_refresh_revision FOREIGN KEY (domain_id, source_id, revision) REFERENCES public.trust_source_revision(domain_id, source_id, revision) ON DELETE CASCADE;


--
-- Name: trust_source_refresh_attempt fk_trust_source_refresh_snapshot; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_source_refresh_attempt
    ADD CONSTRAINT fk_trust_source_refresh_snapshot FOREIGN KEY (domain_id, source_id, revision, resulting_snapshot_id) REFERENCES public.trust_source_snapshot(domain_id, source_id, revision, snapshot_id) ON DELETE RESTRICT;


--
-- Name: trust_source_revision_egress_host fk_trust_source_revision_egress_revision; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_source_revision_egress_host
    ADD CONSTRAINT fk_trust_source_revision_egress_revision FOREIGN KEY (domain_id, source_id, revision) REFERENCES public.trust_source_revision(domain_id, source_id, revision) ON DELETE CASCADE;


--
-- Name: trust_source_revision_signer_anchor fk_trust_source_revision_signer_anchor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_source_revision_signer_anchor
    ADD CONSTRAINT fk_trust_source_revision_signer_anchor FOREIGN KEY (domain_id, anchor_id) REFERENCES public.trust_anchor(domain_id, anchor_id) ON DELETE RESTRICT;


--
-- Name: trust_source_revision_signer_anchor fk_trust_source_revision_signer_revision; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_source_revision_signer_anchor
    ADD CONSTRAINT fk_trust_source_revision_signer_revision FOREIGN KEY (domain_id, source_id, revision) REFERENCES public.trust_source_revision(domain_id, source_id, revision) ON DELETE CASCADE;


--
-- Name: trust_source_revision fk_trust_source_revision_source; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_source_revision
    ADD CONSTRAINT fk_trust_source_revision_source FOREIGN KEY (domain_id, source_id) REFERENCES public.trust_source(domain_id, source_id) ON DELETE CASCADE;


--
-- Name: trust_source_snapshot_artifact fk_trust_source_snapshot_artifact_snapshot; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_source_snapshot_artifact
    ADD CONSTRAINT fk_trust_source_snapshot_artifact_snapshot FOREIGN KEY (domain_id, source_id, revision, snapshot_id) REFERENCES public.trust_source_snapshot(domain_id, source_id, revision, snapshot_id) ON DELETE CASCADE;


--
-- Name: trust_source_snapshot fk_trust_source_snapshot_revision; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_source_snapshot
    ADD CONSTRAINT fk_trust_source_snapshot_revision FOREIGN KEY (domain_id, source_id, revision) REFERENCES public.trust_source_revision(domain_id, source_id, revision) ON DELETE CASCADE;


--
-- Name: trust_source_validation_evidence fk_trust_source_validation_revision; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_source_validation_evidence
    ADD CONSTRAINT fk_trust_source_validation_revision FOREIGN KEY (domain_id, source_id, revision) REFERENCES public.trust_source_revision(domain_id, source_id, revision) ON DELETE CASCADE;


--
-- Name: user_party fk_user_party_party; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_party
    ADD CONSTRAINT fk_user_party_party FOREIGN KEY (party_id) REFERENCES public.party(id) ON DELETE CASCADE;


--
-- Name: verifier fk_verifier_credential_actor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.verifier
    ADD CONSTRAINT fk_verifier_credential_actor FOREIGN KEY (party_id) REFERENCES public.credential_actor(party_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: verifier_credential_definition fk_verifier_credential_definition_credential_definition_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.verifier_credential_definition
    ADD CONSTRAINT fk_verifier_credential_definition_credential_definition_id FOREIGN KEY (credential_definition_id) REFERENCES public.credential_definition(id) ON DELETE CASCADE;


--
-- Name: global_tenant_secret_policy_provider_type global_tenant_secret_policy_provider_type_policy_key_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.global_tenant_secret_policy_provider_type
    ADD CONSTRAINT global_tenant_secret_policy_provider_type_policy_key_fkey FOREIGN KEY (policy_key) REFERENCES public.global_tenant_secret_policy(policy_key) ON DELETE CASCADE;


--
-- Name: group_ group__party_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_
    ADD CONSTRAINT group__party_id_fkey FOREIGN KEY (party_id) REFERENCES public.party(id) ON DELETE CASCADE;


--
-- Name: group_ group__tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_
    ADD CONSTRAINT group__tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenant(id);


--
-- Name: group_membership group_membership_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_membership
    ADD CONSTRAINT group_membership_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.group_(party_id) ON DELETE CASCADE;


--
-- Name: group_membership group_membership_member_party_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_membership
    ADD CONSTRAINT group_membership_member_party_id_fkey FOREIGN KEY (member_party_id) REFERENCES public.party(id);


--
-- Name: group_membership group_membership_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_membership
    ADD CONSTRAINT group_membership_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenant(id);


--
-- Name: group_role group_role_group_party_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_role
    ADD CONSTRAINT group_role_group_party_id_fkey FOREIGN KEY (group_party_id) REFERENCES public.group_party(party_id) ON DELETE CASCADE;


--
-- Name: group_role group_role_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_role
    ADD CONSTRAINT group_role_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.role(id) ON DELETE CASCADE;


--
-- Name: identifier_electronic identifier_electronic_identifier_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identifier_electronic
    ADD CONSTRAINT identifier_electronic_identifier_id_fkey FOREIGN KEY (identifier_id) REFERENCES public.identity_identifier(id) ON DELETE CASCADE;


--
-- Name: identifier_registration identifier_registration_identifier_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identifier_registration
    ADD CONSTRAINT identifier_registration_identifier_id_fkey FOREIGN KEY (identifier_id) REFERENCES public.identity_identifier(id) ON DELETE CASCADE;


--
-- Name: identifier_x509 identifier_x509_identifier_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identifier_x509
    ADD CONSTRAINT identifier_x509_identifier_id_fkey FOREIGN KEY (identifier_id) REFERENCES public.identity_identifier(id) ON DELETE CASCADE;


--
-- Name: identity_application_binding identity_application_binding_application_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_application_binding
    ADD CONSTRAINT identity_application_binding_application_id_fkey FOREIGN KEY (application_id) REFERENCES public.party(id) ON DELETE CASCADE;


--
-- Name: identity_application_binding identity_application_binding_identity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_application_binding
    ADD CONSTRAINT identity_application_binding_identity_id_fkey FOREIGN KEY (identity_id) REFERENCES public.identity(party_id) ON DELETE CASCADE;


--
-- Name: identity_application_binding identity_application_binding_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_application_binding
    ADD CONSTRAINT identity_application_binding_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenant(id);


--
-- Name: identity_application_session_revocation_outbox identity_application_session_revocation_outbox_binding_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_application_session_revocation_outbox
    ADD CONSTRAINT identity_application_session_revocation_outbox_binding_id_fkey FOREIGN KEY (binding_id) REFERENCES public.identity_application_binding(id) ON DELETE CASCADE;


--
-- Name: identity_identifier identity_identifier_identity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_identifier
    ADD CONSTRAINT identity_identifier_identity_id_fkey FOREIGN KEY (identity_id) REFERENCES public.identity(party_id) ON DELETE CASCADE;


--
-- Name: identity_identifier identity_identifier_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_identifier
    ADD CONSTRAINT identity_identifier_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenant(id);


--
-- Name: identity_party_binding identity_party_binding_identity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_party_binding
    ADD CONSTRAINT identity_party_binding_identity_id_fkey FOREIGN KEY (identity_id) REFERENCES public.identity(party_id) ON DELETE CASCADE;


--
-- Name: identity_party_binding identity_party_binding_party_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_party_binding
    ADD CONSTRAINT identity_party_binding_party_id_fkey FOREIGN KEY (party_id) REFERENCES public.party(id) ON DELETE CASCADE;


--
-- Name: identity_party_binding identity_party_binding_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_party_binding
    ADD CONSTRAINT identity_party_binding_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenant(id);


--
-- Name: identity identity_party_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity
    ADD CONSTRAINT identity_party_id_fkey FOREIGN KEY (party_id) REFERENCES public.party(id) ON DELETE CASCADE;


--
-- Name: identity identity_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity
    ADD CONSTRAINT identity_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenant(id);


--
-- Name: kms_secret_payload kms_secret_payload_consumer_tenant_id_tenant_binding_id_de_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.kms_secret_payload
    ADD CONSTRAINT kms_secret_payload_consumer_tenant_id_tenant_binding_id_de_fkey FOREIGN KEY (consumer_tenant_id, tenant_binding_id, definition_id, revision) REFERENCES public.tenant_provider_binding(tenant_id, binding_id, definition_id, provider_revision) ON DELETE RESTRICT;


--
-- Name: kms_secret_payload kms_secret_payload_definition_id_revision_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.kms_secret_payload
    ADD CONSTRAINT kms_secret_payload_definition_id_revision_fkey FOREIGN KEY (definition_id, revision) REFERENCES public.secret_provider_revision(definition_id, revision) ON DELETE RESTRICT;


--
-- Name: kv_version_link kv_version_link_stream_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.kv_version_link
    ADD CONSTRAINT kv_version_link_stream_id_fkey FOREIGN KEY (stream_id) REFERENCES public.kv_versioned_stream(id) ON DELETE CASCADE;


--
-- Name: kv_version kv_version_stream_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.kv_version
    ADD CONSTRAINT kv_version_stream_id_fkey FOREIGN KEY (stream_id) REFERENCES public.kv_versioned_stream(id) ON DELETE CASCADE;


--
-- Name: lote_remote_provider_entry lote_remote_provider_entry_tenant_id_domain_id_source_id_s_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lote_remote_provider_entry
    ADD CONSTRAINT lote_remote_provider_entry_tenant_id_domain_id_source_id_s_fkey FOREIGN KEY (tenant_id, domain_id, source_id, snapshot_id) REFERENCES public.lote_remote_snapshot(tenant_id, domain_id, source_id, snapshot_id) ON DELETE CASCADE;


--
-- Name: lote_remote_refresh_attempt lote_remote_refresh_attempt_tenant_id_domain_id_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lote_remote_refresh_attempt
    ADD CONSTRAINT lote_remote_refresh_attempt_tenant_id_domain_id_source_id_fkey FOREIGN KEY (tenant_id, domain_id, source_id) REFERENCES public.lote_remote_source(tenant_id, domain_id, source_id) ON DELETE CASCADE;


--
-- Name: lote_remote_revision lote_remote_revision_tenant_id_domain_id_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lote_remote_revision
    ADD CONSTRAINT lote_remote_revision_tenant_id_domain_id_source_id_fkey FOREIGN KEY (tenant_id, domain_id, source_id) REFERENCES public.lote_remote_source(tenant_id, domain_id, source_id) ON DELETE CASCADE;


--
-- Name: lote_remote_snapshot lote_remote_snapshot_tenant_id_domain_id_source_id_revisio_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lote_remote_snapshot
    ADD CONSTRAINT lote_remote_snapshot_tenant_id_domain_id_source_id_revisio_fkey FOREIGN KEY (tenant_id, domain_id, source_id, revision) REFERENCES public.lote_remote_revision(tenant_id, domain_id, source_id, revision) ON DELETE CASCADE;


--
-- Name: mdoc_vical_configuration mdoc_vical_configuration_domain_id_anchor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mdoc_vical_configuration
    ADD CONSTRAINT mdoc_vical_configuration_domain_id_anchor_id_fkey FOREIGN KEY (domain_id, anchor_id) REFERENCES public.trust_anchor(domain_id, anchor_id) ON DELETE CASCADE;


--
-- Name: oid4vp_auth_session oid4vp_auth_session_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oid4vp_auth_session
    ADD CONSTRAINT oid4vp_auth_session_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.session(id) ON DELETE CASCADE;


--
-- Name: organization_registration organization_registration_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_registration
    ADD CONSTRAINT organization_registration_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organization(party_id) ON DELETE CASCADE;


--
-- Name: organization_unit organization_unit_party_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_unit
    ADD CONSTRAINT organization_unit_party_id_fkey FOREIGN KEY (party_id) REFERENCES public.party(id) ON DELETE CASCADE;


--
-- Name: organization_unit organization_unit_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_unit
    ADD CONSTRAINT organization_unit_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenant(id);


--
-- Name: party_external_relationship party_external_relationship_party_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.party_external_relationship
    ADD CONSTRAINT party_external_relationship_party_id_fkey FOREIGN KEY (party_id) REFERENCES public.party(id);


--
-- Name: party_external_relationship party_external_relationship_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.party_external_relationship
    ADD CONSTRAINT party_external_relationship_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenant(id);


--
-- Name: party_relationship party_relationship_relationship_type_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.party_relationship
    ADD CONSTRAINT party_relationship_relationship_type_fkey FOREIGN KEY (relationship_type) REFERENCES public.relationship_type(type);


--
-- Name: party_specialization party_specialization_party_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.party_specialization
    ADD CONSTRAINT party_specialization_party_id_fkey FOREIGN KEY (party_id) REFERENCES public.party(id) ON DELETE CASCADE;


--
-- Name: party_specialization party_specialization_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.party_specialization
    ADD CONSTRAINT party_specialization_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenant(id);


--
-- Name: physical_address physical_address_party_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.physical_address
    ADD CONSTRAINT physical_address_party_id_fkey FOREIGN KEY (party_id) REFERENCES public.party(id) ON DELETE CASCADE;


--
-- Name: physical_address physical_address_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.physical_address
    ADD CONSTRAINT physical_address_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenant(id);


--
-- Name: platform_bootstrap_credential_generation platform_bootstrap_credential_generation_credential_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_bootstrap_credential_generation
    ADD CONSTRAINT platform_bootstrap_credential_generation_credential_id_fkey FOREIGN KEY (credential_id) REFERENCES public.platform_bootstrap_credential(credential_id) ON DELETE RESTRICT;


--
-- Name: platform_secret_provider_offering platform_secret_provider_offe_definition_id_published_revi_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_secret_provider_offering
    ADD CONSTRAINT platform_secret_provider_offe_definition_id_published_revi_fkey FOREIGN KEY (definition_id, published_revision) REFERENCES public.secret_provider_revision(definition_id, revision) ON DELETE RESTRICT;


--
-- Name: policy_assignment policy_assignment_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.policy_assignment
    ADD CONSTRAINT policy_assignment_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.resource_category(id) ON DELETE CASCADE;


--
-- Name: policy_assignment policy_assignment_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.policy_assignment
    ADD CONSTRAINT policy_assignment_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.resource_group(id) ON DELETE CASCADE;


--
-- Name: policy_assignment policy_assignment_policy_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.policy_assignment
    ADD CONSTRAINT policy_assignment_policy_id_fkey FOREIGN KEY (policy_id) REFERENCES public.usage_policy(id) ON DELETE CASCADE;


--
-- Name: policy_assignment policy_assignment_resource_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.policy_assignment
    ADD CONSTRAINT policy_assignment_resource_id_fkey FOREIGN KEY (resource_id) REFERENCES public.resource(party_id) ON DELETE CASCADE;


--
-- Name: relationship_employment relationship_employment_relationship_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.relationship_employment
    ADD CONSTRAINT relationship_employment_relationship_id_fkey FOREIGN KEY (relationship_id) REFERENCES public.party_relationship(id) ON DELETE CASCADE;


--
-- Name: resource_group resource_group_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_group
    ADD CONSTRAINT resource_group_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.resource_category(id);


--
-- Name: resource_requirement resource_requirement_resource_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_requirement
    ADD CONSTRAINT resource_requirement_resource_id_fkey FOREIGN KEY (resource_id) REFERENCES public.resource(party_id) ON DELETE CASCADE;


--
-- Name: resource resource_resource_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource
    ADD CONSTRAINT resource_resource_category_id_fkey FOREIGN KEY (resource_category_id) REFERENCES public.resource_category(id);


--
-- Name: resource resource_resource_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource
    ADD CONSTRAINT resource_resource_group_id_fkey FOREIGN KEY (resource_group_id) REFERENCES public.resource_group(id);


--
-- Name: resource_schedule resource_schedule_resource_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_schedule
    ADD CONSTRAINT resource_schedule_resource_id_fkey FOREIGN KEY (resource_id) REFERENCES public.resource(party_id) ON DELETE CASCADE;


--
-- Name: resource_usage_policy resource_usage_policy_resource_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_usage_policy
    ADD CONSTRAINT resource_usage_policy_resource_id_fkey FOREIGN KEY (resource_id) REFERENCES public.resource(party_id) ON DELETE CASCADE;


--
-- Name: resource_usage_policy resource_usage_policy_usage_policy_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resource_usage_policy
    ADD CONSTRAINT resource_usage_policy_usage_policy_id_fkey FOREIGN KEY (usage_policy_id) REFERENCES public.usage_policy(id) ON DELETE CASCADE;


--
-- Name: schedule_rule schedule_rule_schedule_set_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedule_rule
    ADD CONSTRAINT schedule_rule_schedule_set_id_fkey FOREIGN KEY (schedule_set_id) REFERENCES public.schedule_set(id) ON DELETE CASCADE;


--
-- Name: schedule_set_assignment schedule_set_assignment_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedule_set_assignment
    ADD CONSTRAINT schedule_set_assignment_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.resource_category(id) ON DELETE CASCADE;


--
-- Name: schedule_set_assignment schedule_set_assignment_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedule_set_assignment
    ADD CONSTRAINT schedule_set_assignment_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.resource_group(id) ON DELETE CASCADE;


--
-- Name: schedule_set_assignment schedule_set_assignment_resource_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedule_set_assignment
    ADD CONSTRAINT schedule_set_assignment_resource_id_fkey FOREIGN KEY (resource_id) REFERENCES public.resource(party_id) ON DELETE CASCADE;


--
-- Name: schedule_set_assignment schedule_set_assignment_schedule_set_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedule_set_assignment
    ADD CONSTRAINT schedule_set_assignment_schedule_set_id_fkey FOREIGN KEY (schedule_set_id) REFERENCES public.schedule_set(id) ON DELETE CASCADE;


--
-- Name: schedule_set_inclusion schedule_set_inclusion_included_set_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedule_set_inclusion
    ADD CONSTRAINT schedule_set_inclusion_included_set_id_fkey FOREIGN KEY (included_set_id) REFERENCES public.schedule_set(id) ON DELETE CASCADE;


--
-- Name: schedule_set_inclusion schedule_set_inclusion_parent_set_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedule_set_inclusion
    ADD CONSTRAINT schedule_set_inclusion_parent_set_id_fkey FOREIGN KEY (parent_set_id) REFERENCES public.schedule_set(id) ON DELETE CASCADE;


--
-- Name: secret_assignment_write_fence secret_assignment_write_fence_assignment_id_consumer_tenan_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_assignment_write_fence
    ADD CONSTRAINT secret_assignment_write_fence_assignment_id_consumer_tenan_fkey FOREIGN KEY (assignment_id, consumer_tenant_id) REFERENCES public.secret_provider_assignment(assignment_id, consumer_tenant_id) ON DELETE RESTRICT;


--
-- Name: secret_assignment_write_fence secret_assignment_write_fence_migration_id_consumer_tenant_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_assignment_write_fence
    ADD CONSTRAINT secret_assignment_write_fence_migration_id_consumer_tenant_fkey FOREIGN KEY (migration_id, consumer_tenant_id) REFERENCES public.secret_migration_journal(migration_id, consumer_tenant_id) ON DELETE RESTRICT;


--
-- Name: secret_authority_grant secret_authority_grant_manifest_generation_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_authority_grant
    ADD CONSTRAINT secret_authority_grant_manifest_generation_fkey FOREIGN KEY (manifest_generation) REFERENCES public.secret_authority_manifest(generation) ON DELETE RESTRICT;


--
-- Name: secret_credential_material_clear_field secret_credential_material_clear_field_transition_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_credential_material_clear_field
    ADD CONSTRAINT secret_credential_material_clear_field_transition_id_fkey FOREIGN KEY (transition_id) REFERENCES public.secret_credential_material_stage(transition_id) ON DELETE RESTRICT;


--
-- Name: secret_credential_material_stage secret_credential_material_stage_definition_id_revision_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_credential_material_stage
    ADD CONSTRAINT secret_credential_material_stage_definition_id_revision_fkey FOREIGN KEY (definition_id, revision) REFERENCES public.secret_provider_revision(definition_id, revision) ON DELETE RESTRICT;


--
-- Name: secret_credential_material_stage secret_credential_material_stage_transition_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_credential_material_stage
    ADD CONSTRAINT secret_credential_material_stage_transition_id_fkey FOREIGN KEY (transition_id) REFERENCES public.secret_transition_idempotency(transition_id) ON DELETE RESTRICT;


--
-- Name: secret_credential_rotation_journal secret_credential_rotation_jo_consumer_tenant_id_tenant_bi_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_credential_rotation_journal
    ADD CONSTRAINT secret_credential_rotation_jo_consumer_tenant_id_tenant_bi_fkey FOREIGN KEY (consumer_tenant_id, tenant_binding_id, definition_id, revision) REFERENCES public.tenant_provider_binding(tenant_id, binding_id, definition_id, provider_revision) ON DELETE RESTRICT;


--
-- Name: secret_credential_rotation_journal secret_credential_rotation_jo_definition_id_provider_owner_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_credential_rotation_journal
    ADD CONSTRAINT secret_credential_rotation_jo_definition_id_provider_owner_fkey FOREIGN KEY (definition_id, provider_owner_scope) REFERENCES public.secret_provider_definition(definition_id, owner_scope) ON DELETE RESTRICT;


--
-- Name: secret_credential_rotation_journal secret_credential_rotation_journal_definition_id_revision_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_credential_rotation_journal
    ADD CONSTRAINT secret_credential_rotation_journal_definition_id_revision_fkey FOREIGN KEY (definition_id, revision) REFERENCES public.secret_provider_revision(definition_id, revision) ON DELETE RESTRICT;


--
-- Name: secret_initial_tenant_assignment_journal secret_initial_tenant_assignm_preflight_id_tenant_id_tenan_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_initial_tenant_assignment_journal
    ADD CONSTRAINT secret_initial_tenant_assignm_preflight_id_tenant_id_tenan_fkey FOREIGN KEY (preflight_id, tenant_id, tenant_binding_id, definition_id, revision) REFERENCES public.secret_preflight_journal(preflight_id, consumer_tenant_id, target_tenant_binding_id, target_definition_id, target_revision) ON DELETE RESTRICT;


--
-- Name: secret_initial_tenant_assignment_journal secret_initial_tenant_assignm_tenant_id_tenant_binding_id__fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_initial_tenant_assignment_journal
    ADD CONSTRAINT secret_initial_tenant_assignm_tenant_id_tenant_binding_id__fkey FOREIGN KEY (tenant_id, tenant_binding_id, definition_id, revision) REFERENCES public.tenant_provider_binding(tenant_id, binding_id, definition_id, provider_revision) ON DELETE RESTRICT;


--
-- Name: secret_initial_tenant_assignment_journal secret_initial_tenant_assignment_j_assignment_id_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_initial_tenant_assignment_journal
    ADD CONSTRAINT secret_initial_tenant_assignment_j_assignment_id_tenant_id_fkey FOREIGN KEY (assignment_id, tenant_id) REFERENCES public.secret_provider_assignment(assignment_id, consumer_tenant_id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: secret_initial_tenant_assignment_journal secret_initial_tenant_assignment_journal_transition_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_initial_tenant_assignment_journal
    ADD CONSTRAINT secret_initial_tenant_assignment_journal_transition_id_fkey FOREIGN KEY (transition_id) REFERENCES public.secret_transition_idempotency(transition_id) ON DELETE RESTRICT;


--
-- Name: secret_kms_resource_mutation_binding_result secret_kms_resource_mutation_binding_result_mutation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_kms_resource_mutation_binding_result
    ADD CONSTRAINT secret_kms_resource_mutation_binding_result_mutation_id_fkey FOREIGN KEY (mutation_id) REFERENCES public.secret_kms_resource_mutation(mutation_id) ON DELETE RESTRICT;


--
-- Name: secret_kms_resource_mutation secret_kms_resource_mutation_owner_tenant_id_resource_inst_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_kms_resource_mutation
    ADD CONSTRAINT secret_kms_resource_mutation_owner_tenant_id_resource_inst_fkey FOREIGN KEY (owner_tenant_id, resource_instance_key) REFERENCES public.secret_kms_resource_record(owner_tenant_id, resource_instance_key) ON DELETE RESTRICT;


--
-- Name: secret_kms_resource_mutation_result secret_kms_resource_mutation_result_mutation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_kms_resource_mutation_result
    ADD CONSTRAINT secret_kms_resource_mutation_result_mutation_id_fkey FOREIGN KEY (mutation_id) REFERENCES public.secret_kms_resource_mutation(mutation_id) ON DELETE RESTRICT;


--
-- Name: secret_kms_resource_public_handle secret_kms_resource_public_ha_owner_tenant_id_resource_ins_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_kms_resource_public_handle
    ADD CONSTRAINT secret_kms_resource_public_ha_owner_tenant_id_resource_ins_fkey FOREIGN KEY (owner_tenant_id, resource_instance_key) REFERENCES public.secret_kms_resource_record(owner_tenant_id, resource_instance_key) ON DELETE RESTRICT;


--
-- Name: secret_kms_resource_record secret_kms_resource_record_provider_definition_id_provider_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_kms_resource_record
    ADD CONSTRAINT secret_kms_resource_record_provider_definition_id_provider_fkey FOREIGN KEY (provider_definition_id, provider_revision) REFERENCES public.secret_provider_revision_kms_authority_metadata(definition_id, revision) ON DELETE RESTRICT;


--
-- Name: secret_kms_resource_sharing secret_kms_resource_sharing_owner_tenant_id_resource_insta_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_kms_resource_sharing
    ADD CONSTRAINT secret_kms_resource_sharing_owner_tenant_id_resource_insta_fkey FOREIGN KEY (owner_tenant_id, resource_instance_key) REFERENCES public.secret_kms_resource_record(owner_tenant_id, resource_instance_key) ON DELETE CASCADE;


--
-- Name: secret_kms_resource_sharing_tenant secret_kms_resource_sharing_t_owner_tenant_id_resource_ins_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_kms_resource_sharing_tenant
    ADD CONSTRAINT secret_kms_resource_sharing_t_owner_tenant_id_resource_ins_fkey FOREIGN KEY (owner_tenant_id, resource_instance_key) REFERENCES public.secret_kms_resource_sharing(owner_tenant_id, resource_instance_key) ON DELETE CASCADE;


--
-- Name: secret_kms_resource_sharing_withdrawal secret_kms_resource_sharing_w_owner_tenant_id_resource_ins_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_kms_resource_sharing_withdrawal
    ADD CONSTRAINT secret_kms_resource_sharing_w_owner_tenant_id_resource_ins_fkey FOREIGN KEY (owner_tenant_id, resource_instance_key) REFERENCES public.secret_kms_resource_sharing(owner_tenant_id, resource_instance_key) ON DELETE CASCADE;


--
-- Name: secret_migration_action_journal secret_migration_action_journ_migration_id_consumer_tenant_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_migration_action_journal
    ADD CONSTRAINT secret_migration_action_journ_migration_id_consumer_tenant_fkey FOREIGN KEY (migration_id, consumer_tenant_id) REFERENCES public.secret_migration_journal(migration_id, consumer_tenant_id) ON DELETE RESTRICT;


--
-- Name: secret_migration_action_journal secret_migration_action_journal_transition_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_migration_action_journal
    ADD CONSTRAINT secret_migration_action_journal_transition_id_fkey FOREIGN KEY (transition_id) REFERENCES public.secret_transition_idempotency(transition_id) ON DELETE RESTRICT;


--
-- Name: secret_migration_item secret_migration_item_migration_id_consumer_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_migration_item
    ADD CONSTRAINT secret_migration_item_migration_id_consumer_tenant_id_fkey FOREIGN KEY (migration_id, consumer_tenant_id) REFERENCES public.secret_migration_journal(migration_id, consumer_tenant_id) ON DELETE RESTRICT;


--
-- Name: secret_migration_item secret_migration_item_secret_id_secret_owner_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_migration_item
    ADD CONSTRAINT secret_migration_item_secret_id_secret_owner_tenant_id_fkey FOREIGN KEY (secret_id, secret_owner_tenant_id) REFERENCES public.secret_record(secret_id, owner_tenant_id) ON DELETE RESTRICT;


--
-- Name: secret_migration_journal secret_migration_journal_preflight_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_migration_journal
    ADD CONSTRAINT secret_migration_journal_preflight_id_fkey FOREIGN KEY (preflight_id) REFERENCES public.secret_preflight_journal(preflight_id) ON DELETE RESTRICT;


--
-- Name: secret_migration_journal secret_migration_journal_source_assignment_id_consumer_ten_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_migration_journal
    ADD CONSTRAINT secret_migration_journal_source_assignment_id_consumer_ten_fkey FOREIGN KEY (source_assignment_id, consumer_tenant_id) REFERENCES public.secret_provider_assignment(assignment_id, consumer_tenant_id) ON DELETE RESTRICT;


--
-- Name: secret_migration_journal secret_migration_journal_target_assignment_id_consumer_ten_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_migration_journal
    ADD CONSTRAINT secret_migration_journal_target_assignment_id_consumer_ten_fkey FOREIGN KEY (target_assignment_id, consumer_tenant_id, target_definition_id, target_revision) REFERENCES public.secret_provider_assignment(assignment_id, consumer_tenant_id, definition_id, revision) ON DELETE RESTRICT;


--
-- Name: secret_migration_journal secret_migration_journal_target_definition_id_target_revis_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_migration_journal
    ADD CONSTRAINT secret_migration_journal_target_definition_id_target_revis_fkey FOREIGN KEY (target_definition_id, target_revision) REFERENCES public.secret_provider_revision(definition_id, revision) ON DELETE RESTRICT;


--
-- Name: secret_offering_provisioning_journal secret_offering_provisioning__offering_id_definition_id_re_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_offering_provisioning_journal
    ADD CONSTRAINT secret_offering_provisioning__offering_id_definition_id_re_fkey FOREIGN KEY (offering_id, definition_id, revision) REFERENCES public.platform_secret_provider_offering(offering_id, definition_id, published_revision) ON DELETE RESTRICT;


--
-- Name: secret_offering_provisioning_journal secret_offering_provisioning_journal_transition_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_offering_provisioning_journal
    ADD CONSTRAINT secret_offering_provisioning_journal_transition_id_fkey FOREIGN KEY (transition_id) REFERENCES public.secret_transition_idempotency(transition_id) ON DELETE RESTRICT;


--
-- Name: secret_preflight_journal secret_preflight_journal_consumer_tenant_id_target_tenant__fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_preflight_journal
    ADD CONSTRAINT secret_preflight_journal_consumer_tenant_id_target_tenant__fkey FOREIGN KEY (consumer_tenant_id, target_tenant_binding_id, target_definition_id, target_revision) REFERENCES public.tenant_provider_binding(tenant_id, binding_id, definition_id, provider_revision) ON DELETE RESTRICT;


--
-- Name: secret_preflight_journal secret_preflight_journal_target_definition_id_target_owner_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_preflight_journal
    ADD CONSTRAINT secret_preflight_journal_target_definition_id_target_owner_fkey FOREIGN KEY (target_definition_id, target_owner_scope) REFERENCES public.secret_provider_definition(definition_id, owner_scope) ON DELETE RESTRICT;


--
-- Name: secret_preflight_journal secret_preflight_journal_target_definition_id_target_revis_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_preflight_journal
    ADD CONSTRAINT secret_preflight_journal_target_definition_id_target_revis_fkey FOREIGN KEY (target_definition_id, target_revision) REFERENCES public.secret_provider_revision(definition_id, revision) ON DELETE RESTRICT;


--
-- Name: secret_provider_assignment secret_provider_assignment_consumer_tenant_id_tenant_bindi_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_assignment
    ADD CONSTRAINT secret_provider_assignment_consumer_tenant_id_tenant_bindi_fkey FOREIGN KEY (consumer_tenant_id, tenant_binding_id, definition_id, revision) REFERENCES public.tenant_provider_binding(tenant_id, binding_id, definition_id, provider_revision) ON DELETE RESTRICT;


--
-- Name: secret_provider_assignment secret_provider_assignment_definition_id_provider_owner_sc_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_assignment
    ADD CONSTRAINT secret_provider_assignment_definition_id_provider_owner_sc_fkey FOREIGN KEY (definition_id, provider_owner_scope) REFERENCES public.secret_provider_definition(definition_id, owner_scope) ON DELETE RESTRICT;


--
-- Name: secret_provider_assignment secret_provider_assignment_definition_id_revision_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_assignment
    ADD CONSTRAINT secret_provider_assignment_definition_id_revision_fkey FOREIGN KEY (definition_id, revision) REFERENCES public.secret_provider_revision(definition_id, revision) ON DELETE RESTRICT;


--
-- Name: secret_provider_bootstrap_credential_material secret_provider_bootstrap_cre_definition_id_revision_crede_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_bootstrap_credential_material
    ADD CONSTRAINT secret_provider_bootstrap_cre_definition_id_revision_crede_fkey FOREIGN KEY (definition_id, revision, credential_field) REFERENCES public.secret_provider_credential_binding(definition_id, revision, credential_field) ON DELETE RESTRICT;


--
-- Name: secret_provider_bootstrap_credential_material secret_provider_bootstrap_cre_material_credential_id_mater_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_bootstrap_credential_material
    ADD CONSTRAINT secret_provider_bootstrap_cre_material_credential_id_mater_fkey FOREIGN KEY (material_credential_id, material_generation) REFERENCES public.platform_bootstrap_credential_generation(credential_id, generation) ON DELETE RESTRICT;


--
-- Name: secret_provider_cache_impact secret_provider_cache_impact_definition_id_revision_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_cache_impact
    ADD CONSTRAINT secret_provider_cache_impact_definition_id_revision_fkey FOREIGN KEY (definition_id, revision) REFERENCES public.secret_provider_revision(definition_id, revision) ON DELETE RESTRICT;


--
-- Name: secret_provider_credential_binding secret_provider_credential_binding_definition_id_revision_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_credential_binding
    ADD CONSTRAINT secret_provider_credential_binding_definition_id_revision_fkey FOREIGN KEY (definition_id, revision) REFERENCES public.secret_provider_revision(definition_id, revision) ON DELETE RESTRICT;


--
-- Name: secret_provider_environment_manifest_item secret_provider_environment_manifes_definition_id_revision_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_environment_manifest_item
    ADD CONSTRAINT secret_provider_environment_manifes_definition_id_revision_fkey FOREIGN KEY (definition_id, revision) REFERENCES public.secret_provider_revision_environment(definition_id, revision) ON DELETE RESTRICT;


--
-- Name: secret_provider_health secret_provider_health_definition_id_revision_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_health
    ADD CONSTRAINT secret_provider_health_definition_id_revision_fkey FOREIGN KEY (definition_id, revision) REFERENCES public.secret_provider_revision(definition_id, revision) ON DELETE RESTRICT;


--
-- Name: secret_provider_kubernetes_mount_manifest_item secret_provider_kubernetes_mount_ma_definition_id_revision_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_kubernetes_mount_manifest_item
    ADD CONSTRAINT secret_provider_kubernetes_mount_ma_definition_id_revision_fkey FOREIGN KEY (definition_id, revision) REFERENCES public.secret_provider_revision_kubernetes_mount(definition_id, revision) ON DELETE RESTRICT;


--
-- Name: secret_provider_platform_credential_material secret_provider_platform_cred_definition_id_revision_crede_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_platform_credential_material
    ADD CONSTRAINT secret_provider_platform_cred_definition_id_revision_crede_fkey FOREIGN KEY (definition_id, revision, credential_field) REFERENCES public.secret_provider_credential_binding(definition_id, revision, credential_field) ON DELETE RESTRICT;


--
-- Name: secret_provider_platform_credential_material secret_provider_platform_cred_material_secret_id_material__fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_platform_credential_material
    ADD CONSTRAINT secret_provider_platform_cred_material_secret_id_material__fkey FOREIGN KEY (material_secret_id, material_owner_tenant_id, material_generation) REFERENCES public.secret_record_generation(secret_id, owner_tenant_id, generation) ON DELETE RESTRICT;


--
-- Name: secret_provider_revision_aws secret_provider_revision_aws_definition_id_revision_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_revision_aws
    ADD CONSTRAINT secret_provider_revision_aws_definition_id_revision_fkey FOREIGN KEY (definition_id, revision) REFERENCES public.secret_provider_revision(definition_id, revision) ON DELETE RESTRICT;


--
-- Name: secret_provider_revision_azure secret_provider_revision_azure_definition_id_revision_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_revision_azure
    ADD CONSTRAINT secret_provider_revision_azure_definition_id_revision_fkey FOREIGN KEY (definition_id, revision) REFERENCES public.secret_provider_revision(definition_id, revision) ON DELETE RESTRICT;


--
-- Name: secret_provider_revision_capability secret_provider_revision_capability_definition_id_revision_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_revision_capability
    ADD CONSTRAINT secret_provider_revision_capability_definition_id_revision_fkey FOREIGN KEY (definition_id, revision) REFERENCES public.secret_provider_revision(definition_id, revision) ON DELETE CASCADE;


--
-- Name: secret_provider_revision secret_provider_revision_definition_id_owner_scope_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_revision
    ADD CONSTRAINT secret_provider_revision_definition_id_owner_scope_fkey FOREIGN KEY (definition_id, owner_scope) REFERENCES public.secret_provider_definition(definition_id, owner_scope) ON DELETE RESTRICT;


--
-- Name: secret_provider_revision_environment secret_provider_revision_environmen_definition_id_revision_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_revision_environment
    ADD CONSTRAINT secret_provider_revision_environmen_definition_id_revision_fkey FOREIGN KEY (definition_id, revision) REFERENCES public.secret_provider_revision(definition_id, revision) ON DELETE RESTRICT;


--
-- Name: secret_provider_revision_kms_operation_metadata secret_provider_revision_kms__credential_storage_provider__fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_revision_kms_operation_metadata
    ADD CONSTRAINT secret_provider_revision_kms__credential_storage_provider__fkey FOREIGN KEY (credential_storage_provider_definition_id, credential_storage_provider_revision) REFERENCES public.secret_provider_revision(definition_id, revision) ON DELETE RESTRICT;


--
-- Name: secret_provider_revision_kms_authority_credential_slot secret_provider_revision_kms_autho_definition_id_revision_fkey1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_revision_kms_authority_credential_slot
    ADD CONSTRAINT secret_provider_revision_kms_autho_definition_id_revision_fkey1 FOREIGN KEY (definition_id, revision) REFERENCES public.secret_provider_revision_kms_authority_metadata(definition_id, revision) ON DELETE RESTRICT;


--
-- Name: secret_provider_revision_kms_authority_metadata secret_provider_revision_kms_author_definition_id_revision_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_revision_kms_authority_metadata
    ADD CONSTRAINT secret_provider_revision_kms_author_definition_id_revision_fkey FOREIGN KEY (definition_id, revision) REFERENCES public.secret_provider_revision_kms(definition_id, revision) ON DELETE RESTRICT;


--
-- Name: secret_provider_revision_kms secret_provider_revision_kms_definition_id_revision_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_revision_kms
    ADD CONSTRAINT secret_provider_revision_kms_definition_id_revision_fkey FOREIGN KEY (definition_id, revision) REFERENCES public.secret_provider_revision(definition_id, revision) ON DELETE RESTRICT;


--
-- Name: secret_provider_revision_kms_operation_metadata secret_provider_revision_kms_operat_definition_id_revision_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_revision_kms_operation_metadata
    ADD CONSTRAINT secret_provider_revision_kms_operat_definition_id_revision_fkey FOREIGN KEY (definition_id, revision) REFERENCES public.secret_provider_revision_kms_authority_metadata(definition_id, revision) ON DELETE RESTRICT;


--
-- Name: secret_provider_revision_kubernetes_mount secret_provider_revision_kubernetes_definition_id_revision_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_revision_kubernetes_mount
    ADD CONSTRAINT secret_provider_revision_kubernetes_definition_id_revision_fkey FOREIGN KEY (definition_id, revision) REFERENCES public.secret_provider_revision(definition_id, revision) ON DELETE RESTRICT;


--
-- Name: secret_provider_revision_transition secret_provider_revision_transition_definition_id_revision_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_revision_transition
    ADD CONSTRAINT secret_provider_revision_transition_definition_id_revision_fkey FOREIGN KEY (definition_id, revision) REFERENCES public.secret_provider_revision(definition_id, revision) ON DELETE RESTRICT;


--
-- Name: secret_provider_revision_transition secret_provider_revision_transition_latest_preflight_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_revision_transition
    ADD CONSTRAINT secret_provider_revision_transition_latest_preflight_id_fkey FOREIGN KEY (latest_preflight_id) REFERENCES public.secret_preflight_journal(preflight_id) ON DELETE RESTRICT;


--
-- Name: secret_provider_revision_vault secret_provider_revision_vault_definition_id_revision_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_provider_revision_vault
    ADD CONSTRAINT secret_provider_revision_vault_definition_id_revision_fkey FOREIGN KEY (definition_id, revision) REFERENCES public.secret_provider_revision(definition_id, revision) ON DELETE RESTRICT;


--
-- Name: secret_purge_journal secret_purge_journal_retention_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_purge_journal
    ADD CONSTRAINT secret_purge_journal_retention_id_fkey FOREIGN KEY (retention_id) REFERENCES public.secret_retention_journal(retention_id) ON DELETE RESTRICT;


--
-- Name: secret_record secret_record_assignment_id_storage_consumer_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_record
    ADD CONSTRAINT secret_record_assignment_id_storage_consumer_tenant_id_fkey FOREIGN KEY (assignment_id, storage_consumer_tenant_id) REFERENCES public.secret_provider_assignment(assignment_id, consumer_tenant_id) ON DELETE RESTRICT;


--
-- Name: secret_record_generation secret_record_generation_secret_id_owner_tenant_id_record__fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_record_generation
    ADD CONSTRAINT secret_record_generation_secret_id_owner_tenant_id_record__fkey FOREIGN KEY (secret_id, owner_tenant_id, record_class) REFERENCES public.secret_record(secret_id, owner_tenant_id, record_class) ON DELETE RESTRICT;


--
-- Name: secret_resource_credential_binding secret_resource_credential_bi_owner_tenant_id_tenant_bindi_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_resource_credential_binding
    ADD CONSTRAINT secret_resource_credential_bi_owner_tenant_id_tenant_bindi_fkey FOREIGN KEY (owner_tenant_id, tenant_binding_id, provider_definition_id, provider_revision) REFERENCES public.tenant_provider_binding(tenant_id, binding_id, definition_id, provider_revision) ON DELETE RESTRICT;


--
-- Name: secret_resource_credential_binding secret_resource_credential_bi_provider_definition_id_provi_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_resource_credential_binding
    ADD CONSTRAINT secret_resource_credential_bi_provider_definition_id_provi_fkey FOREIGN KEY (provider_definition_id, provider_revision) REFERENCES public.secret_provider_revision(definition_id, revision) ON DELETE RESTRICT;


--
-- Name: secret_resource_credential_binding secret_resource_credential_bi_secret_id_owner_tenant_id_se_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_resource_credential_binding
    ADD CONSTRAINT secret_resource_credential_bi_secret_id_owner_tenant_id_se_fkey FOREIGN KEY (secret_id, owner_tenant_id, secret_generation, record_class) REFERENCES public.secret_record_generation(secret_id, owner_tenant_id, generation, record_class) ON DELETE RESTRICT;


--
-- Name: secret_resource_credential_binding secret_resource_credential_binding_provider_assignment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_resource_credential_binding
    ADD CONSTRAINT secret_resource_credential_binding_provider_assignment_id_fkey FOREIGN KEY (provider_assignment_id) REFERENCES public.secret_provider_assignment(assignment_id) ON DELETE RESTRICT;


--
-- Name: secret_retention_journal secret_retention_journal_migration_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_retention_journal
    ADD CONSTRAINT secret_retention_journal_migration_id_fkey FOREIGN KEY (migration_id) REFERENCES public.secret_migration_journal(migration_id) ON DELETE RESTRICT;


--
-- Name: secret_server_kms_resource_binding secret_server_kms_resource_bi_provider_definition_id_provi_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_server_kms_resource_binding
    ADD CONSTRAINT secret_server_kms_resource_bi_provider_definition_id_provi_fkey FOREIGN KEY (provider_definition_id, provider_revision) REFERENCES public.secret_provider_revision(definition_id, revision) ON DELETE RESTRICT;


--
-- Name: secret_server_kms_resource_binding secret_server_kms_resource_binding_product_offering_key_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_server_kms_resource_binding
    ADD CONSTRAINT secret_server_kms_resource_binding_product_offering_key_fkey FOREIGN KEY (product_offering_key) REFERENCES public.secret_server_kms_resource_offering(product_offering_key) ON DELETE RESTRICT;


--
-- Name: secret_transition_bootstrap_material_receipt secret_transition_bootstrap_material__operation_id_slot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_transition_bootstrap_material_receipt
    ADD CONSTRAINT secret_transition_bootstrap_material__operation_id_slot_id_fkey FOREIGN KEY (operation_id, slot_id) REFERENCES public.secret_transition_material_slot(operation_id, slot_id) ON DELETE RESTRICT;


--
-- Name: secret_transition_idempotency secret_transition_idempotency_result_definition_id_result__fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_transition_idempotency
    ADD CONSTRAINT secret_transition_idempotency_result_definition_id_result__fkey FOREIGN KEY (result_definition_id, result_revision) REFERENCES public.secret_provider_revision(definition_id, revision) ON DELETE RESTRICT;


--
-- Name: secret_transition_material_slot secret_transition_material_slot_definition_id_revision_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_transition_material_slot
    ADD CONSTRAINT secret_transition_material_slot_definition_id_revision_fkey FOREIGN KEY (definition_id, revision) REFERENCES public.secret_provider_revision(definition_id, revision) ON DELETE RESTRICT;


--
-- Name: secret_transition_material_slot secret_transition_material_slot_operation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_transition_material_slot
    ADD CONSTRAINT secret_transition_material_slot_operation_id_fkey FOREIGN KEY (operation_id) REFERENCES public.secret_transition_idempotency(transition_id) ON DELETE RESTRICT;


--
-- Name: secret_transition_platform_material_receipt secret_transition_platform_ma_secret_record_id_owner_tenan_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_transition_platform_material_receipt
    ADD CONSTRAINT secret_transition_platform_ma_secret_record_id_owner_tenan_fkey FOREIGN KEY (secret_record_id, owner_tenant_id, generation) REFERENCES public.secret_record_generation(secret_id, owner_tenant_id, generation) ON DELETE RESTRICT;


--
-- Name: secret_transition_platform_material_receipt secret_transition_platform_material_r_operation_id_slot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_transition_platform_material_receipt
    ADD CONSTRAINT secret_transition_platform_material_r_operation_id_slot_id_fkey FOREIGN KEY (operation_id, slot_id) REFERENCES public.secret_transition_material_slot(operation_id, slot_id) ON DELETE RESTRICT;


--
-- Name: secret_value_mutation_journal secret_value_mutation_journal_delegated_capability_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_value_mutation_journal
    ADD CONSTRAINT secret_value_mutation_journal_delegated_capability_id_fkey FOREIGN KEY (delegated_capability_id) REFERENCES public.tenant_secret_delegated_capability(capability_id) ON DELETE RESTRICT;


--
-- Name: secret_value_mutation_journal secret_value_mutation_journal_secret_id_consumer_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_value_mutation_journal
    ADD CONSTRAINT secret_value_mutation_journal_secret_id_consumer_tenant_id_fkey FOREIGN KEY (secret_id, consumer_tenant_id) REFERENCES public.secret_record(secret_id, owner_tenant_id) ON DELETE RESTRICT;


--
-- Name: secret_value_mutation_journal secret_value_mutation_journal_source_assignment_id_consume_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_value_mutation_journal
    ADD CONSTRAINT secret_value_mutation_journal_source_assignment_id_consume_fkey FOREIGN KEY (source_assignment_id, consumer_tenant_id) REFERENCES public.secret_provider_assignment(assignment_id, consumer_tenant_id) ON DELETE RESTRICT;


--
-- Name: service service_party_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service
    ADD CONSTRAINT service_party_id_fkey FOREIGN KEY (party_id) REFERENCES public.party(id) ON DELETE CASCADE;


--
-- Name: service service_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service
    ADD CONSTRAINT service_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenant(id);


--
-- Name: system_credential_reference system_credential_reference_record_purpose_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_credential_reference
    ADD CONSTRAINT system_credential_reference_record_purpose_fkey FOREIGN KEY (secret_id, owner_tenant_id, record_class, purpose) REFERENCES public.secret_record(secret_id, owner_tenant_id, record_class, purpose) ON DELETE RESTRICT;


--
-- Name: system_credential_reference system_credential_reference_secret_id_owner_tenant_id_gene_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_credential_reference
    ADD CONSTRAINT system_credential_reference_secret_id_owner_tenant_id_gene_fkey FOREIGN KEY (secret_id, owner_tenant_id, generation, record_class) REFERENCES public.secret_record_generation(secret_id, owner_tenant_id, generation, record_class) ON DELETE RESTRICT;


--
-- Name: system_credential_reference system_credential_reference_secret_id_owner_tenant_id_reco_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_credential_reference
    ADD CONSTRAINT system_credential_reference_secret_id_owner_tenant_id_reco_fkey FOREIGN KEY (secret_id, owner_tenant_id, record_class) REFERENCES public.secret_record(secret_id, owner_tenant_id, record_class) ON DELETE RESTRICT;


--
-- Name: system_credential_transition_material system_credential_transition__storage_assignment_id_storag_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_credential_transition_material
    ADD CONSTRAINT system_credential_transition__storage_assignment_id_storag_fkey FOREIGN KEY (storage_assignment_id, storage_consumer_tenant_id) REFERENCES public.secret_provider_assignment(assignment_id, consumer_tenant_id) ON DELETE RESTRICT;


--
-- Name: system_credential_transition_material system_credential_transition_mat_secret_id_owner_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_credential_transition_material
    ADD CONSTRAINT system_credential_transition_mat_secret_id_owner_tenant_id_fkey FOREIGN KEY (secret_id, owner_tenant_id) REFERENCES public.secret_record(secret_id, owner_tenant_id) ON DELETE RESTRICT;


--
-- Name: system_credential_transition_material system_credential_transition_material_operation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_credential_transition_material
    ADD CONSTRAINT system_credential_transition_material_operation_id_fkey FOREIGN KEY (operation_id) REFERENCES public.system_credential_transition(operation_id) ON DELETE RESTRICT;


--
-- Name: system_credential_transition system_credential_transition_owner_tenant_id_workload_acto_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_credential_transition
    ADD CONSTRAINT system_credential_transition_owner_tenant_id_workload_acto_fkey FOREIGN KEY (owner_tenant_id, workload_actor_id, purpose, secret_id) REFERENCES public.system_credential_reference(owner_tenant_id, workload_actor_id, purpose, secret_id) ON DELETE RESTRICT;


--
-- Name: system_credential_transition system_credential_transition_secret_id_owner_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_credential_transition
    ADD CONSTRAINT system_credential_transition_secret_id_owner_tenant_id_fkey FOREIGN KEY (secret_id, owner_tenant_id) REFERENCES public.secret_record(secret_id, owner_tenant_id) ON DELETE RESTRICT;


--
-- Name: system_credential_use_binding system_credential_use_binding_owner_tenant_id_workload_act_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_credential_use_binding
    ADD CONSTRAINT system_credential_use_binding_owner_tenant_id_workload_act_fkey FOREIGN KEY (owner_tenant_id, workload_actor_id, purpose, secret_id) REFERENCES public.system_credential_reference(owner_tenant_id, workload_actor_id, purpose, secret_id) ON DELETE RESTRICT;


--
-- Name: system_credential_use_binding system_credential_use_binding_secret_id_owner_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_credential_use_binding
    ADD CONSTRAINT system_credential_use_binding_secret_id_owner_tenant_id_fkey FOREIGN KEY (secret_id, owner_tenant_id) REFERENCES public.secret_record(secret_id, owner_tenant_id) ON DELETE RESTRICT;


--
-- Name: tenant tenant_owner_party_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant
    ADD CONSTRAINT tenant_owner_party_id_fkey FOREIGN KEY (owner_party_id) REFERENCES public.party(id);


--
-- Name: tenant_provider_binding tenant_provider_binding_offering_id_definition_id_provider_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_provider_binding
    ADD CONSTRAINT tenant_provider_binding_offering_id_definition_id_provider_fkey FOREIGN KEY (offering_id, definition_id, provider_revision) REFERENCES public.platform_secret_provider_offering(offering_id, definition_id, published_revision) ON DELETE RESTRICT;


--
-- Name: tenant_provider_capability_generation tenant_provider_capability_generation_tenant_id_binding_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_provider_capability_generation
    ADD CONSTRAINT tenant_provider_capability_generation_tenant_id_binding_id_fkey FOREIGN KEY (tenant_id, binding_id) REFERENCES public.tenant_provider_binding(tenant_id, binding_id) ON DELETE RESTRICT;


--
-- Name: tenant_provider_capability_material tenant_provider_capability_ma_capability_secret_id_tenant__fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_provider_capability_material
    ADD CONSTRAINT tenant_provider_capability_ma_capability_secret_id_tenant__fkey FOREIGN KEY (capability_secret_id, tenant_id, material_generation) REFERENCES public.secret_record_generation(secret_id, owner_tenant_id, generation) ON DELETE RESTRICT;


--
-- Name: tenant_provider_capability_material tenant_provider_capability_ma_tenant_id_binding_id_capabil_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_provider_capability_material
    ADD CONSTRAINT tenant_provider_capability_ma_tenant_id_binding_id_capabil_fkey FOREIGN KEY (tenant_id, binding_id, capability_generation) REFERENCES public.tenant_provider_capability_generation(tenant_id, binding_id, capability_generation) ON DELETE RESTRICT;


--
-- Name: tenant_provider_isolation_proof_vault tenant_provider_isolation_pr_tenant_id_binding_id_capabil_fkey1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_provider_isolation_proof_vault
    ADD CONSTRAINT tenant_provider_isolation_pr_tenant_id_binding_id_capabil_fkey1 FOREIGN KEY (tenant_id, binding_id, capability_generation) REFERENCES public.tenant_provider_capability_generation(tenant_id, binding_id, capability_generation) ON DELETE RESTRICT;


--
-- Name: tenant_provider_isolation_proof_azure tenant_provider_isolation_pr_tenant_id_binding_id_capabil_fkey2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_provider_isolation_proof_azure
    ADD CONSTRAINT tenant_provider_isolation_pr_tenant_id_binding_id_capabil_fkey2 FOREIGN KEY (tenant_id, binding_id, capability_generation) REFERENCES public.tenant_provider_capability_generation(tenant_id, binding_id, capability_generation) ON DELETE RESTRICT;


--
-- Name: tenant_provider_isolation_proof_aws tenant_provider_isolation_pr_tenant_id_binding_id_capabil_fkey3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_provider_isolation_proof_aws
    ADD CONSTRAINT tenant_provider_isolation_pr_tenant_id_binding_id_capabil_fkey3 FOREIGN KEY (tenant_id, binding_id, capability_generation) REFERENCES public.tenant_provider_capability_generation(tenant_id, binding_id, capability_generation) ON DELETE RESTRICT;


--
-- Name: tenant_provider_isolation_proof_kms tenant_provider_isolation_pro_tenant_id_binding_id_capabil_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_provider_isolation_proof_kms
    ADD CONSTRAINT tenant_provider_isolation_pro_tenant_id_binding_id_capabil_fkey FOREIGN KEY (tenant_id, binding_id, capability_generation) REFERENCES public.tenant_provider_capability_generation(tenant_id, binding_id, capability_generation) ON DELETE RESTRICT;


--
-- Name: tenant_secret_delegated_capability_purpose tenant_secret_delegated_capability_purpose_capability_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_secret_delegated_capability_purpose
    ADD CONSTRAINT tenant_secret_delegated_capability_purpose_capability_id_fkey FOREIGN KEY (capability_id) REFERENCES public.tenant_secret_delegated_capability(capability_id) ON DELETE CASCADE;


--
-- Name: tenant_secret_policy_override_provider_type tenant_secret_policy_override_provider_type_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_secret_policy_override_provider_type
    ADD CONSTRAINT tenant_secret_policy_override_provider_type_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenant_secret_policy_override(tenant_id) ON DELETE CASCADE;


--
-- Name: tenant_user tenant_user_user_party_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_user
    ADD CONSTRAINT tenant_user_user_party_id_fkey FOREIGN KEY (user_party_id) REFERENCES public.user_party(party_id) ON DELETE CASCADE;


--
-- Name: user_party user_party_natural_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_party
    ADD CONSTRAINT user_party_natural_person_id_fkey FOREIGN KEY (natural_person_id) REFERENCES public.natural_person(party_id);


--
-- Name: user_role user_role_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_role
    ADD CONSTRAINT user_role_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.role(id) ON DELETE CASCADE;


--
-- Name: user_role user_role_user_party_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_role
    ADD CONSTRAINT user_role_user_party_id_fkey FOREIGN KEY (user_party_id) REFERENCES public.user_party(party_id) ON DELETE CASCADE;


--
-- Name: kms_secret_payload; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.kms_secret_payload ENABLE ROW LEVEL SECURITY;

--
-- Name: platform_bootstrap_credential_generation; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.platform_bootstrap_credential_generation ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_access_grant; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_access_grant ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_assignment_write_fence; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_assignment_write_fence ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_authority_grant; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_authority_grant ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_authority_manifest; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_authority_manifest ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_collection_version; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_collection_version ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_credential_material_clear_field; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_credential_material_clear_field ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_credential_material_stage; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_credential_material_stage ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_credential_rotation_journal; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_credential_rotation_journal ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_initial_tenant_assignment_journal; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_initial_tenant_assignment_journal ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_kms_resource_mutation; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_kms_resource_mutation ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_kms_resource_mutation_binding_result; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_kms_resource_mutation_binding_result ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_kms_resource_mutation_result; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_kms_resource_mutation_result ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_kms_resource_public_handle; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_kms_resource_public_handle ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_kms_resource_record; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_kms_resource_record ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_kms_resource_sharing; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_kms_resource_sharing ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_kms_resource_sharing_tenant; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_kms_resource_sharing_tenant ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_kms_resource_sharing_withdrawal; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_kms_resource_sharing_withdrawal ENABLE ROW LEVEL SECURITY;

--
-- Name: kms_secret_payload secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.kms_secret_payload USING (((CURRENT_USER = 'secret_management_admin'::name) OR (consumer_tenant_id = current_setting('app.consumer_tenant_id'::text, true)))) WITH CHECK (((CURRENT_USER = 'secret_management_admin'::name) OR (consumer_tenant_id = current_setting('app.consumer_tenant_id'::text, true))));


--
-- Name: platform_bootstrap_credential_generation secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.platform_bootstrap_credential_generation USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_access_grant secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_access_grant USING (((CURRENT_USER = 'secret_management_admin'::name) OR (tenant_id = current_setting('app.consumer_tenant_id'::text, true)))) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_assignment_write_fence secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_assignment_write_fence USING (((CURRENT_USER = 'secret_management_admin'::name) OR (consumer_tenant_id = current_setting('app.consumer_tenant_id'::text, true)))) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_authority_grant secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_authority_grant USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_authority_manifest secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_authority_manifest USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_collection_version secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_collection_version USING (((CURRENT_USER = 'secret_management_admin'::name) OR ((scope_kind = 'TENANT'::text) AND (scope_id = current_setting('app.consumer_tenant_id'::text, true)) AND (collection_kind <> 'INTERNAL_SECRET'::text)))) WITH CHECK (((CURRENT_USER = 'secret_management_admin'::name) OR ((scope_kind = 'TENANT'::text) AND (scope_id = current_setting('app.consumer_tenant_id'::text, true)) AND (collection_kind <> 'INTERNAL_SECRET'::text))));


--
-- Name: secret_credential_material_clear_field secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_credential_material_clear_field USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_credential_material_stage secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_credential_material_stage USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_credential_rotation_journal secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_credential_rotation_journal USING (((CURRENT_USER = 'secret_management_admin'::name) OR (consumer_tenant_id = current_setting('app.consumer_tenant_id'::text, true)))) WITH CHECK (((CURRENT_USER = 'secret_management_admin'::name) OR (consumer_tenant_id = current_setting('app.consumer_tenant_id'::text, true))));


--
-- Name: secret_initial_tenant_assignment_journal secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_initial_tenant_assignment_journal USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_kms_resource_mutation secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_kms_resource_mutation USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_kms_resource_mutation_binding_result secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_kms_resource_mutation_binding_result USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_kms_resource_mutation_result secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_kms_resource_mutation_result USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_kms_resource_public_handle secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_kms_resource_public_handle USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_kms_resource_record secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_kms_resource_record USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_kms_resource_sharing secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_kms_resource_sharing USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_kms_resource_sharing_tenant secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_kms_resource_sharing_tenant USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_kms_resource_sharing_withdrawal secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_kms_resource_sharing_withdrawal USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_migration_action_journal secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_migration_action_journal USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_migration_item secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_migration_item USING (((CURRENT_USER = 'secret_management_admin'::name) OR (consumer_tenant_id = current_setting('app.consumer_tenant_id'::text, true)))) WITH CHECK (((CURRENT_USER = 'secret_management_admin'::name) OR (consumer_tenant_id = current_setting('app.consumer_tenant_id'::text, true))));


--
-- Name: secret_migration_journal secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_migration_journal USING (((CURRENT_USER = 'secret_management_admin'::name) OR (consumer_tenant_id = current_setting('app.consumer_tenant_id'::text, true)))) WITH CHECK (((CURRENT_USER = 'secret_management_admin'::name) OR (consumer_tenant_id = current_setting('app.consumer_tenant_id'::text, true))));


--
-- Name: secret_offering_provisioning_journal secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_offering_provisioning_journal USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_orphan_cleanup_journal secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_orphan_cleanup_journal USING (((CURRENT_USER = 'secret_management_admin'::name) OR (consumer_tenant_id = current_setting('app.consumer_tenant_id'::text, true)))) WITH CHECK (((CURRENT_USER = 'secret_management_admin'::name) OR (consumer_tenant_id = current_setting('app.consumer_tenant_id'::text, true))));


--
-- Name: secret_permit_replay_state secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_permit_replay_state USING ((CURRENT_USER = ANY (ARRAY['secret_management_admin'::name, 'secret_management_runtime'::name]))) WITH CHECK ((CURRENT_USER = ANY (ARRAY['secret_management_admin'::name, 'secret_management_runtime'::name])));


--
-- Name: secret_preflight_journal secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_preflight_journal USING (((CURRENT_USER = 'secret_management_admin'::name) OR (consumer_tenant_id = current_setting('app.consumer_tenant_id'::text, true)))) WITH CHECK (((CURRENT_USER = 'secret_management_admin'::name) OR (consumer_tenant_id = current_setting('app.consumer_tenant_id'::text, true))));


--
-- Name: secret_provider_assignment secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_provider_assignment USING (((CURRENT_USER = 'secret_management_admin'::name) OR (consumer_tenant_id = current_setting('app.consumer_tenant_id'::text, true)))) WITH CHECK (((CURRENT_USER = 'secret_management_admin'::name) OR (consumer_tenant_id = current_setting('app.consumer_tenant_id'::text, true))));


--
-- Name: secret_provider_bootstrap_credential_material secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_provider_bootstrap_credential_material USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_provider_cache_impact secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_provider_cache_impact USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_provider_credential_binding secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_provider_credential_binding USING (((CURRENT_USER = 'secret_management_admin'::name) OR (EXISTS ( SELECT 1
   FROM (public.secret_provider_revision r
     LEFT JOIN public.tenant_provider_binding b ON (((b.definition_id = r.definition_id) AND (b.provider_revision = r.revision) AND (b.tenant_id = current_setting('app.consumer_tenant_id'::text, true)) AND (b.lifecycle_state = ANY (ARRAY['READY'::text, 'ACTIVE'::text, 'RETAINED'::text])))))
  WHERE ((r.definition_id = secret_provider_credential_binding.definition_id) AND (r.revision = secret_provider_credential_binding.revision) AND ((r.owner_scope = current_setting('app.consumer_tenant_id'::text, true)) OR (b.binding_id IS NOT NULL))))))) WITH CHECK (((CURRENT_USER = 'secret_management_admin'::name) OR (EXISTS ( SELECT 1
   FROM public.secret_provider_revision r
  WHERE ((r.definition_id = secret_provider_credential_binding.definition_id) AND (r.revision = secret_provider_credential_binding.revision) AND (r.owner_scope = current_setting('app.consumer_tenant_id'::text, true)))))));


--
-- Name: secret_provider_definition secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_provider_definition USING (((CURRENT_USER = 'secret_management_admin'::name) OR (owner_scope = current_setting('app.consumer_tenant_id'::text, true)) OR (EXISTS ( SELECT 1
   FROM public.tenant_provider_binding b
  WHERE ((b.tenant_id = current_setting('app.consumer_tenant_id'::text, true)) AND (b.definition_id = secret_provider_definition.definition_id) AND (b.lifecycle_state = ANY (ARRAY['READY'::text, 'ACTIVE'::text, 'RETAINED'::text]))))) OR (EXISTS ( SELECT 1
   FROM public.platform_secret_provider_offering o
  WHERE ((o.definition_id = secret_provider_definition.definition_id) AND o.enabled AND (o.lifecycle_state = ANY (ARRAY['READY'::text, 'ACTIVE'::text]))))))) WITH CHECK (((CURRENT_USER = 'secret_management_admin'::name) OR (owner_scope = current_setting('app.consumer_tenant_id'::text, true))));


--
-- Name: secret_provider_environment_manifest_item secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_provider_environment_manifest_item USING (((CURRENT_USER = 'secret_management_admin'::name) OR (EXISTS ( SELECT 1
   FROM (public.secret_provider_revision r
     LEFT JOIN public.tenant_provider_binding b ON (((b.definition_id = r.definition_id) AND (b.provider_revision = r.revision) AND (b.tenant_id = current_setting('app.consumer_tenant_id'::text, true)) AND (b.lifecycle_state = ANY (ARRAY['READY'::text, 'ACTIVE'::text, 'RETAINED'::text])))))
  WHERE ((r.definition_id = secret_provider_environment_manifest_item.definition_id) AND (r.revision = secret_provider_environment_manifest_item.revision) AND ((r.owner_scope = current_setting('app.consumer_tenant_id'::text, true)) OR (b.binding_id IS NOT NULL))))))) WITH CHECK (((CURRENT_USER = 'secret_management_admin'::name) OR (EXISTS ( SELECT 1
   FROM public.secret_provider_revision r
  WHERE ((r.definition_id = secret_provider_environment_manifest_item.definition_id) AND (r.revision = secret_provider_environment_manifest_item.revision) AND (r.owner_scope = current_setting('app.consumer_tenant_id'::text, true)))))));


--
-- Name: secret_provider_health secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_provider_health USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_provider_kubernetes_mount_manifest_item secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_provider_kubernetes_mount_manifest_item USING (((CURRENT_USER = 'secret_management_admin'::name) OR (EXISTS ( SELECT 1
   FROM (public.secret_provider_revision r
     LEFT JOIN public.tenant_provider_binding b ON (((b.definition_id = r.definition_id) AND (b.provider_revision = r.revision) AND (b.tenant_id = current_setting('app.consumer_tenant_id'::text, true)) AND (b.lifecycle_state = ANY (ARRAY['READY'::text, 'ACTIVE'::text, 'RETAINED'::text])))))
  WHERE ((r.definition_id = secret_provider_kubernetes_mount_manifest_item.definition_id) AND (r.revision = secret_provider_kubernetes_mount_manifest_item.revision) AND ((r.owner_scope = current_setting('app.consumer_tenant_id'::text, true)) OR (b.binding_id IS NOT NULL))))))) WITH CHECK (((CURRENT_USER = 'secret_management_admin'::name) OR (EXISTS ( SELECT 1
   FROM public.secret_provider_revision r
  WHERE ((r.definition_id = secret_provider_kubernetes_mount_manifest_item.definition_id) AND (r.revision = secret_provider_kubernetes_mount_manifest_item.revision) AND (r.owner_scope = current_setting('app.consumer_tenant_id'::text, true)))))));


--
-- Name: secret_provider_platform_credential_material secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_provider_platform_credential_material USING (((CURRENT_USER = 'secret_management_admin'::name) OR (material_owner_tenant_id = current_setting('app.consumer_tenant_id'::text, true)))) WITH CHECK (((CURRENT_USER = 'secret_management_admin'::name) OR (material_owner_tenant_id = current_setting('app.consumer_tenant_id'::text, true))));


--
-- Name: secret_provider_revision secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_provider_revision USING (((CURRENT_USER = 'secret_management_admin'::name) OR (owner_scope = current_setting('app.consumer_tenant_id'::text, true)) OR (EXISTS ( SELECT 1
   FROM public.tenant_provider_binding b
  WHERE ((b.tenant_id = current_setting('app.consumer_tenant_id'::text, true)) AND (b.definition_id = secret_provider_revision.definition_id) AND (b.provider_revision = secret_provider_revision.revision) AND (b.lifecycle_state = ANY (ARRAY['READY'::text, 'ACTIVE'::text, 'RETAINED'::text]))))) OR (EXISTS ( SELECT 1
   FROM public.platform_secret_provider_offering o
  WHERE ((o.definition_id = secret_provider_revision.definition_id) AND (o.published_revision = secret_provider_revision.revision) AND o.enabled AND (o.lifecycle_state = ANY (ARRAY['READY'::text, 'ACTIVE'::text]))))))) WITH CHECK (((CURRENT_USER = 'secret_management_admin'::name) OR (owner_scope = current_setting('app.consumer_tenant_id'::text, true))));


--
-- Name: secret_provider_revision_aws secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_provider_revision_aws USING (((CURRENT_USER = 'secret_management_admin'::name) OR (EXISTS ( SELECT 1
   FROM (public.secret_provider_revision r
     LEFT JOIN public.tenant_provider_binding b ON (((b.definition_id = r.definition_id) AND (b.provider_revision = r.revision) AND (b.tenant_id = current_setting('app.consumer_tenant_id'::text, true)) AND (b.lifecycle_state = ANY (ARRAY['READY'::text, 'ACTIVE'::text, 'RETAINED'::text])))))
  WHERE ((r.definition_id = secret_provider_revision_aws.definition_id) AND (r.revision = secret_provider_revision_aws.revision) AND ((r.owner_scope = current_setting('app.consumer_tenant_id'::text, true)) OR (b.binding_id IS NOT NULL))))))) WITH CHECK (((CURRENT_USER = 'secret_management_admin'::name) OR (EXISTS ( SELECT 1
   FROM public.secret_provider_revision r
  WHERE ((r.definition_id = secret_provider_revision_aws.definition_id) AND (r.revision = secret_provider_revision_aws.revision) AND (r.owner_scope = current_setting('app.consumer_tenant_id'::text, true)))))));


--
-- Name: secret_provider_revision_azure secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_provider_revision_azure USING (((CURRENT_USER = 'secret_management_admin'::name) OR (EXISTS ( SELECT 1
   FROM (public.secret_provider_revision r
     LEFT JOIN public.tenant_provider_binding b ON (((b.definition_id = r.definition_id) AND (b.provider_revision = r.revision) AND (b.tenant_id = current_setting('app.consumer_tenant_id'::text, true)) AND (b.lifecycle_state = ANY (ARRAY['READY'::text, 'ACTIVE'::text, 'RETAINED'::text])))))
  WHERE ((r.definition_id = secret_provider_revision_azure.definition_id) AND (r.revision = secret_provider_revision_azure.revision) AND ((r.owner_scope = current_setting('app.consumer_tenant_id'::text, true)) OR (b.binding_id IS NOT NULL))))))) WITH CHECK (((CURRENT_USER = 'secret_management_admin'::name) OR (EXISTS ( SELECT 1
   FROM public.secret_provider_revision r
  WHERE ((r.definition_id = secret_provider_revision_azure.definition_id) AND (r.revision = secret_provider_revision_azure.revision) AND (r.owner_scope = current_setting('app.consumer_tenant_id'::text, true)))))));


--
-- Name: secret_provider_revision_capability secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_provider_revision_capability USING (((CURRENT_USER = 'secret_management_admin'::name) OR (EXISTS ( SELECT 1
   FROM ((public.secret_provider_revision r
     LEFT JOIN public.tenant_provider_binding b ON (((b.definition_id = r.definition_id) AND (b.provider_revision = r.revision) AND (b.tenant_id = current_setting('app.consumer_tenant_id'::text, true)) AND (b.lifecycle_state = ANY (ARRAY['READY'::text, 'ACTIVE'::text, 'RETAINED'::text])))))
     LEFT JOIN public.platform_secret_provider_offering o ON (((o.definition_id = r.definition_id) AND (o.published_revision = r.revision) AND o.enabled AND (o.lifecycle_state = ANY (ARRAY['READY'::text, 'ACTIVE'::text])))))
  WHERE ((r.definition_id = secret_provider_revision_capability.definition_id) AND (r.revision = secret_provider_revision_capability.revision) AND ((r.owner_scope = current_setting('app.consumer_tenant_id'::text, true)) OR (b.binding_id IS NOT NULL) OR (o.offering_id IS NOT NULL))))))) WITH CHECK (((CURRENT_USER = 'secret_management_admin'::name) OR (EXISTS ( SELECT 1
   FROM public.secret_provider_revision r
  WHERE ((r.definition_id = secret_provider_revision_capability.definition_id) AND (r.revision = secret_provider_revision_capability.revision) AND (r.owner_scope = current_setting('app.consumer_tenant_id'::text, true)))))));


--
-- Name: secret_provider_revision_environment secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_provider_revision_environment USING (((CURRENT_USER = 'secret_management_admin'::name) OR (EXISTS ( SELECT 1
   FROM (public.secret_provider_revision r
     LEFT JOIN public.tenant_provider_binding b ON (((b.definition_id = r.definition_id) AND (b.provider_revision = r.revision) AND (b.tenant_id = current_setting('app.consumer_tenant_id'::text, true)) AND (b.lifecycle_state = ANY (ARRAY['READY'::text, 'ACTIVE'::text, 'RETAINED'::text])))))
  WHERE ((r.definition_id = secret_provider_revision_environment.definition_id) AND (r.revision = secret_provider_revision_environment.revision) AND ((r.owner_scope = current_setting('app.consumer_tenant_id'::text, true)) OR (b.binding_id IS NOT NULL))))))) WITH CHECK (((CURRENT_USER = 'secret_management_admin'::name) OR (EXISTS ( SELECT 1
   FROM public.secret_provider_revision r
  WHERE ((r.definition_id = secret_provider_revision_environment.definition_id) AND (r.revision = secret_provider_revision_environment.revision) AND (r.owner_scope = current_setting('app.consumer_tenant_id'::text, true)))))));


--
-- Name: secret_provider_revision_kms secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_provider_revision_kms USING (((CURRENT_USER = 'secret_management_admin'::name) OR (EXISTS ( SELECT 1
   FROM (public.secret_provider_revision r
     LEFT JOIN public.tenant_provider_binding b ON (((b.definition_id = r.definition_id) AND (b.provider_revision = r.revision) AND (b.tenant_id = current_setting('app.consumer_tenant_id'::text, true)) AND (b.lifecycle_state = ANY (ARRAY['READY'::text, 'ACTIVE'::text, 'RETAINED'::text])))))
  WHERE ((r.definition_id = secret_provider_revision_kms.definition_id) AND (r.revision = secret_provider_revision_kms.revision) AND ((r.owner_scope = current_setting('app.consumer_tenant_id'::text, true)) OR (b.binding_id IS NOT NULL))))))) WITH CHECK (((CURRENT_USER = 'secret_management_admin'::name) OR (EXISTS ( SELECT 1
   FROM public.secret_provider_revision r
  WHERE ((r.definition_id = secret_provider_revision_kms.definition_id) AND (r.revision = secret_provider_revision_kms.revision) AND (r.owner_scope = current_setting('app.consumer_tenant_id'::text, true)))))));


--
-- Name: secret_provider_revision_kms_authority_credential_slot secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_provider_revision_kms_authority_credential_slot USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_provider_revision_kms_authority_metadata secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_provider_revision_kms_authority_metadata USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_provider_revision_kms_operation_metadata secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_provider_revision_kms_operation_metadata USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_provider_revision_kubernetes_mount secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_provider_revision_kubernetes_mount USING (((CURRENT_USER = 'secret_management_admin'::name) OR (EXISTS ( SELECT 1
   FROM (public.secret_provider_revision r
     LEFT JOIN public.tenant_provider_binding b ON (((b.definition_id = r.definition_id) AND (b.provider_revision = r.revision) AND (b.tenant_id = current_setting('app.consumer_tenant_id'::text, true)) AND (b.lifecycle_state = ANY (ARRAY['READY'::text, 'ACTIVE'::text, 'RETAINED'::text])))))
  WHERE ((r.definition_id = secret_provider_revision_kubernetes_mount.definition_id) AND (r.revision = secret_provider_revision_kubernetes_mount.revision) AND ((r.owner_scope = current_setting('app.consumer_tenant_id'::text, true)) OR (b.binding_id IS NOT NULL))))))) WITH CHECK (((CURRENT_USER = 'secret_management_admin'::name) OR (EXISTS ( SELECT 1
   FROM public.secret_provider_revision r
  WHERE ((r.definition_id = secret_provider_revision_kubernetes_mount.definition_id) AND (r.revision = secret_provider_revision_kubernetes_mount.revision) AND (r.owner_scope = current_setting('app.consumer_tenant_id'::text, true)))))));


--
-- Name: secret_provider_revision_transition secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_provider_revision_transition USING (((CURRENT_USER = 'secret_management_admin'::name) OR (EXISTS ( SELECT 1
   FROM ((public.secret_provider_revision r
     LEFT JOIN public.tenant_provider_binding b ON (((b.definition_id = r.definition_id) AND (b.provider_revision = r.revision) AND (b.tenant_id = current_setting('app.consumer_tenant_id'::text, true)) AND (b.lifecycle_state = ANY (ARRAY['READY'::text, 'ACTIVE'::text, 'RETAINED'::text])))))
     LEFT JOIN public.platform_secret_provider_offering o ON (((o.definition_id = r.definition_id) AND (o.published_revision = r.revision) AND o.enabled AND (o.lifecycle_state = ANY (ARRAY['READY'::text, 'ACTIVE'::text])))))
  WHERE ((r.definition_id = secret_provider_revision_transition.definition_id) AND (r.revision = secret_provider_revision_transition.revision) AND ((r.owner_scope = current_setting('app.consumer_tenant_id'::text, true)) OR (b.binding_id IS NOT NULL) OR (o.offering_id IS NOT NULL))))))) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_provider_revision_vault secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_provider_revision_vault USING (((CURRENT_USER = 'secret_management_admin'::name) OR (EXISTS ( SELECT 1
   FROM (public.secret_provider_revision r
     LEFT JOIN public.tenant_provider_binding b ON (((b.definition_id = r.definition_id) AND (b.provider_revision = r.revision) AND (b.tenant_id = current_setting('app.consumer_tenant_id'::text, true)) AND (b.lifecycle_state = ANY (ARRAY['READY'::text, 'ACTIVE'::text, 'RETAINED'::text])))))
  WHERE ((r.definition_id = secret_provider_revision_vault.definition_id) AND (r.revision = secret_provider_revision_vault.revision) AND ((r.owner_scope = current_setting('app.consumer_tenant_id'::text, true)) OR (b.binding_id IS NOT NULL))))))) WITH CHECK (((CURRENT_USER = 'secret_management_admin'::name) OR (EXISTS ( SELECT 1
   FROM public.secret_provider_revision r
  WHERE ((r.definition_id = secret_provider_revision_vault.definition_id) AND (r.revision = secret_provider_revision_vault.revision) AND (r.owner_scope = current_setting('app.consumer_tenant_id'::text, true)))))));


--
-- Name: secret_purge_journal secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_purge_journal USING (((CURRENT_USER = 'secret_management_admin'::name) OR (EXISTS ( SELECT 1
   FROM (public.secret_retention_journal r
     JOIN public.secret_migration_journal m ON ((m.migration_id = r.migration_id)))
  WHERE ((r.retention_id = secret_purge_journal.retention_id) AND (m.consumer_tenant_id = current_setting('app.consumer_tenant_id'::text, true))))))) WITH CHECK (((CURRENT_USER = 'secret_management_admin'::name) OR (EXISTS ( SELECT 1
   FROM (public.secret_retention_journal r
     JOIN public.secret_migration_journal m ON ((m.migration_id = r.migration_id)))
  WHERE ((r.retention_id = secret_purge_journal.retention_id) AND (m.consumer_tenant_id = current_setting('app.consumer_tenant_id'::text, true)))))));


--
-- Name: secret_record secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_record USING (((CURRENT_USER = 'secret_management_admin'::name) OR ((owner_tenant_id = current_setting('app.consumer_tenant_id'::text, true)) AND (record_class = 'TENANT_VALUE'::text) AND (purpose <> 'internal'::text) AND (purpose !~~ 'internal-%'::text) AND (purpose <> 'oid4vci-issuer-trust-domain-api-client-secret'::text)))) WITH CHECK (((CURRENT_USER = 'secret_management_admin'::name) OR ((owner_tenant_id = current_setting('app.consumer_tenant_id'::text, true)) AND (record_class = 'TENANT_VALUE'::text) AND (purpose <> 'internal'::text) AND (purpose !~~ 'internal-%'::text) AND (purpose <> 'oid4vci-issuer-trust-domain-api-client-secret'::text))));


--
-- Name: secret_record_generation secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_record_generation USING (((CURRENT_USER = 'secret_management_admin'::name) OR (EXISTS ( SELECT 1
   FROM public.secret_record visible_record
  WHERE ((visible_record.secret_id = secret_record_generation.secret_id) AND (visible_record.owner_tenant_id = secret_record_generation.owner_tenant_id) AND (visible_record.owner_tenant_id = current_setting('app.consumer_tenant_id'::text, true)) AND (visible_record.record_class = 'TENANT_VALUE'::text) AND (visible_record.purpose <> 'internal'::text) AND (visible_record.purpose !~~ 'internal-%'::text) AND (visible_record.purpose <> 'oid4vci-issuer-trust-domain-api-client-secret'::text)))))) WITH CHECK (((CURRENT_USER = 'secret_management_admin'::name) OR (EXISTS ( SELECT 1
   FROM public.secret_record visible_record
  WHERE ((visible_record.secret_id = secret_record_generation.secret_id) AND (visible_record.owner_tenant_id = secret_record_generation.owner_tenant_id) AND (visible_record.owner_tenant_id = current_setting('app.consumer_tenant_id'::text, true)) AND (visible_record.record_class = 'TENANT_VALUE'::text) AND (visible_record.purpose <> 'internal'::text) AND (visible_record.purpose !~~ 'internal-%'::text) AND (visible_record.purpose <> 'oid4vci-issuer-trust-domain-api-client-secret'::text))))));


--
-- Name: secret_resource_credential_binding secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_resource_credential_binding USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_retention_journal secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_retention_journal USING (((CURRENT_USER = 'secret_management_admin'::name) OR (EXISTS ( SELECT 1
   FROM public.secret_migration_journal m
  WHERE ((m.migration_id = secret_retention_journal.migration_id) AND (m.consumer_tenant_id = current_setting('app.consumer_tenant_id'::text, true))))))) WITH CHECK (((CURRENT_USER = 'secret_management_admin'::name) OR (EXISTS ( SELECT 1
   FROM public.secret_migration_journal m
  WHERE ((m.migration_id = secret_retention_journal.migration_id) AND (m.consumer_tenant_id = current_setting('app.consumer_tenant_id'::text, true)))))));


--
-- Name: secret_server_kms_resource_binding secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_server_kms_resource_binding USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_server_kms_resource_offering secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_server_kms_resource_offering USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_tenant_kms_default_provider secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_tenant_kms_default_provider USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_tenant_kms_enabled_provider secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_tenant_kms_enabled_provider USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_transition_bootstrap_material_receipt secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_transition_bootstrap_material_receipt USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_transition_idempotency secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_transition_idempotency USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_transition_material_slot secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_transition_material_slot USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_transition_platform_material_receipt secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_transition_platform_material_receipt USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: secret_value_mutation_journal secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.secret_value_mutation_journal USING (((CURRENT_USER = 'secret_management_admin'::name) OR (consumer_tenant_id = current_setting('app.consumer_tenant_id'::text, true)))) WITH CHECK (((CURRENT_USER = 'secret_management_admin'::name) OR (consumer_tenant_id = current_setting('app.consumer_tenant_id'::text, true))));


--
-- Name: system_credential_reference secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.system_credential_reference USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: system_credential_transition secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.system_credential_transition USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: system_credential_transition_material secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.system_credential_transition_material USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: system_credential_use_binding secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.system_credential_use_binding USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: tenant_provider_binding secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.tenant_provider_binding USING (((CURRENT_USER = 'secret_management_admin'::name) OR (tenant_id = current_setting('app.consumer_tenant_id'::text, true)))) WITH CHECK (((CURRENT_USER = 'secret_management_admin'::name) OR (tenant_id = current_setting('app.consumer_tenant_id'::text, true))));


--
-- Name: tenant_provider_capability_generation secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.tenant_provider_capability_generation USING (((CURRENT_USER = 'secret_management_admin'::name) OR (tenant_id = current_setting('app.consumer_tenant_id'::text, true)))) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: tenant_provider_capability_material secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.tenant_provider_capability_material USING (((CURRENT_USER = 'secret_management_admin'::name) OR (tenant_id = current_setting('app.consumer_tenant_id'::text, true)))) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: tenant_provider_isolation_proof_aws secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.tenant_provider_isolation_proof_aws USING (((CURRENT_USER = 'secret_management_admin'::name) OR (tenant_id = current_setting('app.consumer_tenant_id'::text, true)))) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: tenant_provider_isolation_proof_azure secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.tenant_provider_isolation_proof_azure USING (((CURRENT_USER = 'secret_management_admin'::name) OR (tenant_id = current_setting('app.consumer_tenant_id'::text, true)))) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: tenant_provider_isolation_proof_kms secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.tenant_provider_isolation_proof_kms USING (((CURRENT_USER = 'secret_management_admin'::name) OR (tenant_id = current_setting('app.consumer_tenant_id'::text, true)))) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: tenant_provider_isolation_proof_vault secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.tenant_provider_isolation_proof_vault USING (((CURRENT_USER = 'secret_management_admin'::name) OR (tenant_id = current_setting('app.consumer_tenant_id'::text, true)))) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: tenant_secret_delegated_capability secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.tenant_secret_delegated_capability USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: tenant_secret_delegated_capability_purpose secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.tenant_secret_delegated_capability_purpose USING ((CURRENT_USER = 'secret_management_admin'::name)) WITH CHECK ((CURRENT_USER = 'secret_management_admin'::name));


--
-- Name: tenant_secret_policy_override secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.tenant_secret_policy_override USING (((CURRENT_USER = 'secret_management_admin'::name) OR (tenant_id = current_setting('app.consumer_tenant_id'::text, true)))) WITH CHECK (((CURRENT_USER = 'secret_management_admin'::name) OR (tenant_id = current_setting('app.consumer_tenant_id'::text, true))));


--
-- Name: tenant_secret_policy_override_provider_type secret_management_tenant_scope; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secret_management_tenant_scope ON public.tenant_secret_policy_override_provider_type USING (((CURRENT_USER = 'secret_management_admin'::name) OR (tenant_id = current_setting('app.consumer_tenant_id'::text, true)))) WITH CHECK (((CURRENT_USER = 'secret_management_admin'::name) OR (tenant_id = current_setting('app.consumer_tenant_id'::text, true))));


--
-- Name: secret_migration_action_journal; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_migration_action_journal ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_migration_item; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_migration_item ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_migration_journal; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_migration_journal ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_offering_provisioning_journal; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_offering_provisioning_journal ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_orphan_cleanup_journal; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_orphan_cleanup_journal ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_permit_replay_state; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_permit_replay_state ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_preflight_journal; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_preflight_journal ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_provider_assignment; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_provider_assignment ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_provider_bootstrap_credential_material; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_provider_bootstrap_credential_material ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_provider_cache_impact; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_provider_cache_impact ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_provider_credential_binding; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_provider_credential_binding ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_provider_definition; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_provider_definition ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_provider_environment_manifest_item; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_provider_environment_manifest_item ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_provider_health; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_provider_health ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_provider_kubernetes_mount_manifest_item; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_provider_kubernetes_mount_manifest_item ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_provider_platform_credential_material; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_provider_platform_credential_material ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_provider_revision; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_provider_revision ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_provider_revision_aws; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_provider_revision_aws ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_provider_revision_azure; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_provider_revision_azure ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_provider_revision_capability; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_provider_revision_capability ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_provider_revision_environment; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_provider_revision_environment ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_provider_revision_kms; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_provider_revision_kms ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_provider_revision_kms_authority_credential_slot; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_provider_revision_kms_authority_credential_slot ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_provider_revision_kms_authority_metadata; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_provider_revision_kms_authority_metadata ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_provider_revision_kms_operation_metadata; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_provider_revision_kms_operation_metadata ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_provider_revision_kubernetes_mount; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_provider_revision_kubernetes_mount ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_provider_revision_transition; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_provider_revision_transition ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_provider_revision_vault; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_provider_revision_vault ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_purge_journal; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_purge_journal ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_record; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_record ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_record_generation; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_record_generation ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_resource_credential_binding; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_resource_credential_binding ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_retention_journal; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_retention_journal ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_server_kms_resource_binding; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_server_kms_resource_binding ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_server_kms_resource_offering; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_server_kms_resource_offering ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_tenant_kms_default_provider; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_tenant_kms_default_provider ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_tenant_kms_enabled_provider; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_tenant_kms_enabled_provider ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_transition_bootstrap_material_receipt; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_transition_bootstrap_material_receipt ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_transition_idempotency; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_transition_idempotency ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_transition_material_slot; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_transition_material_slot ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_transition_platform_material_receipt; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_transition_platform_material_receipt ENABLE ROW LEVEL SECURITY;

--
-- Name: secret_value_mutation_journal; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secret_value_mutation_journal ENABLE ROW LEVEL SECURITY;

--
-- Name: system_credential_reference; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.system_credential_reference ENABLE ROW LEVEL SECURITY;

--
-- Name: system_credential_transition; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.system_credential_transition ENABLE ROW LEVEL SECURITY;

--
-- Name: system_credential_transition_material; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.system_credential_transition_material ENABLE ROW LEVEL SECURITY;

--
-- Name: system_credential_use_binding; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.system_credential_use_binding ENABLE ROW LEVEL SECURITY;

--
-- Name: tenant_provider_binding; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tenant_provider_binding ENABLE ROW LEVEL SECURITY;

--
-- Name: tenant_provider_capability_generation; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tenant_provider_capability_generation ENABLE ROW LEVEL SECURITY;

--
-- Name: tenant_provider_capability_material; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tenant_provider_capability_material ENABLE ROW LEVEL SECURITY;

--
-- Name: tenant_provider_isolation_proof_aws; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tenant_provider_isolation_proof_aws ENABLE ROW LEVEL SECURITY;

--
-- Name: tenant_provider_isolation_proof_azure; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tenant_provider_isolation_proof_azure ENABLE ROW LEVEL SECURITY;

--
-- Name: tenant_provider_isolation_proof_kms; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tenant_provider_isolation_proof_kms ENABLE ROW LEVEL SECURITY;

--
-- Name: tenant_provider_isolation_proof_vault; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tenant_provider_isolation_proof_vault ENABLE ROW LEVEL SECURITY;

--
-- Name: tenant_secret_delegated_capability; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tenant_secret_delegated_capability ENABLE ROW LEVEL SECURITY;

--
-- Name: tenant_secret_delegated_capability_purpose; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tenant_secret_delegated_capability_purpose ENABLE ROW LEVEL SECURITY;

--
-- Name: tenant_secret_policy_override; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tenant_secret_policy_override ENABLE ROW LEVEL SECURITY;

--
-- Name: tenant_secret_policy_override_provider_type; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tenant_secret_policy_override_provider_type ENABLE ROW LEVEL SECURITY;

--
-- PostgreSQL database dump complete
--

\unrestrict 62ZWUIk87rfRU3Pe43oajfLWMbPWoDfKX6UU2QC2BcZfeRQWfi9txShgGwzEoVN

