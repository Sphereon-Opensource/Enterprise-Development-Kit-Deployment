package sphereon.authz

import rego.v1

default allow = false

# Preserve each existing exact role rule. No wildcard translation is introduced.
allow if {
    required := data.federation_publication_policy.role_rules[input.action.name]
    role := input.principal.attributes.roles[_]
    role == required[_]
}

# The prior configured roles engine permits unmatched commands. Preserve that
# existing transport behavior, while explicitly excluding the new internal drain.
allow if {
    data.federation_publication_policy.legacy_unmatched_default_permit
    input.action.name != "oidfed.entity-publication-work.run"
    not data.federation_publication_policy.role_rules[input.action.name]
}

# Normal AuthZen/OPA decision for the process-owned SERVICE dispatcher only.
# PolicyRequestNormalizer has replaced the typed resource identity with command
# identity, retaining the actual typed tenant and bounded batch in attributes.
allow if {
    input.action.name == "oidfed.entity-publication-work.run"
    input.action.module == "oidfed"
    input.action.service == "entity-publication-work"
    input.action.command == "run"
    input.principal.type == "user"
    input.principal.id == data.federation_publication_policy.worker_id
    input.context.session_principal_type == "service"
    is_string(input.context.tenantId)
    trim_space(input.context.tenantId) != ""
    input.principal.attributes.tenant_id == input.context.tenantId
    input.resource.type == "command"
    input.resource.id == input.action.name
    input.resource.attributes.module == "oidfed"
    input.resource.attributes.service == "entity-publication-work"
    input.resource.attributes.command == "run"
    input.resource.attributes.tenant_id == input.context.tenantId
    is_number(input.resource.attributes.batch_limit)
    floor(input.resource.attributes.batch_limit) == input.resource.attributes.batch_limit
    input.resource.attributes.batch_limit >= 1
    input.resource.attributes.batch_limit <= 32
}

# The command pipeline's pre-execution hook evaluates every selected operation before the command
# runs, with only the command identity as resource (no typed arguments are available there). Admit
# exactly the process-owned SERVICE dispatcher for its own session tenant at that stage. The command's
# own required authorization then evaluates the typed tenant and bounded batch with the rule above.
allow if {
    input.action.name == "oidfed.entity-publication-work.run"
    input.action.module == "oidfed"
    input.action.service == "entity-publication-work"
    input.action.command == "run"
    input.principal.type == "user"
    input.principal.id == data.federation_publication_policy.worker_id
    input.context.session_principal_type == "service"
    is_string(input.context.tenantId)
    trim_space(input.context.tenantId) != ""
    input.principal.attributes.tenant_id == input.context.tenantId
    input.resource.type == "command"
    input.resource.id == input.action.name
    input.resource.attributes.module == "oidfed"
    input.resource.attributes.service == "entity-publication-work"
    input.resource.attributes.command == "run"
    not input.resource.attributes.tenant_id
    not input.resource.attributes.batch_limit
}
