package system.authz

import rego.v1

# OPA is a private decision service. Its policy/data/query administration APIs
# are unavailable; policy and immutable data are supplied by read-only mounts.
default allow = false

# The policy engine asks for the decision member (`allow`), and for `reasons` on a deny, rather than the whole package.
allow if {
    input.method == "POST"
    input.path in {
        ["v1", "data", "sphereon", "authz"],
        ["v1", "data", "sphereon", "authz", "allow"],
        ["v1", "data", "sphereon", "authz", "reasons"],
    }
}

allow if {
    input.method == "GET"
    input.path == ["health"]
}
